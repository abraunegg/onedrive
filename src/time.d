// What is this module called?
module time;

// What does this module require to function?
import core.time : Duration, MonoTime, dur;
import std.conv : to;
import std.datetime;
import std.format : format;
import std.string : strip;

// What other modules that we have created do we need to import?
import config;
import log;
import util : MicrosoftServiceProbeResult, probeMicrosoftService;

// System-time validation policy.
//
// These thresholds are intentionally application policy rather than user
// configuration. HTTP Date is a coarse wall-clock reference, so the decision
// logic applies an uncertainty allowance before comparing against them.
enum long TIME_WARNING_THRESHOLD_MS = 15_000;
enum long TIME_BLOCKING_THRESHOLD_MS = 120_000;
enum long TIME_MAX_ACCEPTABLE_RTT_MS = 5_000;
enum long TIME_HTTP_DATE_BASE_UNCERTAINTY_MS = 1_000;
enum long TIME_MAX_WALL_MONOTONIC_DIVERGENCE_MS = 2_000;
enum long TIME_CONFIRMATION_MAX_DIFFERENCE_MS = 10_000;
enum long TIME_PERIODIC_REVALIDATION_INTERVAL_SECONDS = 300;
enum long TIME_BLOCKED_RETRY_INTERVAL_SECONDS = TIME_PERIODIC_REVALIDATION_INTERVAL_SECONDS;

struct TimeAssessment {
	SystemTimeState state;
	bool validObservation;
	bool blockingConfirmed;
	bool severeWarning;
	bool canClearExistingBlock;
	long signedOffsetMilliseconds;
	long effectiveSkewMilliseconds;
	long roundTripMilliseconds;
	long uncertaintyMilliseconds;
	SysTime remoteServiceTimeUtc;
	SysTime estimatedLocalTimeUtc;
	string authority;
	string reason;
}

private long absoluteLong(long value) {
	return value < 0 ? -value : value;
}

private bool sameOffsetDirection(long first, long second) {
	return (first >= 0 && second >= 0) || (first <= 0 && second <= 0);
}

// Evaluate one already-completed Microsoft service probe. This function performs
// no network I/O and is deterministic for the supplied observation.
TimeAssessment assessMicrosoftServiceTime(MicrosoftServiceProbeResult probe) {
	TimeAssessment assessment;
	assessment.state = SystemTimeState.authorityUnavailable;
	assessment.authority = probe.serviceUrl;
	assessment.reason = probe.failureReason.length ? probe.failureReason : "time_authority_unavailable";

	if (!probe.reachable) {
		return assessment;
	}

	if (strip(probe.responseDateHeader).length == 0) {
		assessment.reason = "date_header_missing";
		return assessment;
	}

	assessment.roundTripMilliseconds = probe.roundTripTime.total!"msecs";
	if (assessment.roundTripMilliseconds < 0 || assessment.roundTripMilliseconds > TIME_MAX_ACCEPTABLE_RTT_MS) {
		assessment.reason = "round_trip_time_too_high";
		return assessment;
	}

	// If wall time changed materially while monotonic time progressed normally,
	// the sample itself cannot be trusted. This can occur when NTP or an operator
	// steps CLOCK_REALTIME during the HTTPS request.
	long wallElapsedMilliseconds = (probe.responseEndUtc - probe.requestStartUtc).total!"msecs";
	long wallMonotonicDifference = absoluteLong(wallElapsedMilliseconds - assessment.roundTripMilliseconds);
	if (wallMonotonicDifference > TIME_MAX_WALL_MONOTONIC_DIVERGENCE_MS) {
		assessment.reason = "local_clock_changed_during_probe";
		return assessment;
	}

	try {
		assessment.remoteServiceTimeUtc = parseRFC822DateTime(strip(probe.responseDateHeader)).toUTC();
	} catch (Exception e) {
		assessment.reason = "date_header_invalid";
		return assessment;
	}

	// HTTP Date does not provide the four timestamps that NTP does. Use the local
	// request midpoint as a coarse estimate and explicitly carry uncertainty from
	// the Date header's one-second granularity plus half the observed RTT.
	assessment.estimatedLocalTimeUtc = probe.requestStartUtc + dur!"msecs"(assessment.roundTripMilliseconds / 2);
	assessment.signedOffsetMilliseconds = (assessment.estimatedLocalTimeUtc - assessment.remoteServiceTimeUtc).total!"msecs";
	assessment.uncertaintyMilliseconds = TIME_HTTP_DATE_BASE_UNCERTAINTY_MS + (assessment.roundTripMilliseconds / 2);

	long absoluteObservedSkew = absoluteLong(assessment.signedOffsetMilliseconds);
	assessment.effectiveSkewMilliseconds = absoluteObservedSkew > assessment.uncertaintyMilliseconds ?
		(absoluteObservedSkew - assessment.uncertaintyMilliseconds) : 0;
	assessment.validObservation = true;
	assessment.reason = "valid_service_time_observation";

	if (assessment.effectiveSkewMilliseconds > TIME_BLOCKING_THRESHOLD_MS) {
		assessment.state = SystemTimeState.blocking;
		assessment.canClearExistingBlock = false;
	} else if (assessment.effectiveSkewMilliseconds > TIME_WARNING_THRESHOLD_MS) {
		assessment.state = SystemTimeState.warning;
		assessment.canClearExistingBlock = true;
	} else {
		assessment.state = SystemTimeState.ok;
		assessment.canClearExistingBlock = true;
	}

	return assessment;
}

private void updateRuntimeTimeState(ApplicationConfig appConfig, TimeAssessment assessment, MicrosoftServiceProbeResult probe) {
	appConfig.previousSystemTimeState = appConfig.systemTimeState;
	appConfig.systemTimeState = assessment.state;
	appConfig.systemTimeLastCheckedUtc = Clock.currTime(UTC());
	appConfig.systemTimeAuthority = assessment.authority;
	appConfig.systemTimeStateReason = assessment.reason;
	appConfig.systemTimeLastValidationAttemptMonotonic = MonoTime.currTime();
	appConfig.systemTimeValidationAttemptRecorded = true;
	appConfig.systemTimeObservedOffsetMilliseconds = assessment.signedOffsetMilliseconds;
	appConfig.systemTimeEffectiveSkewMilliseconds = assessment.effectiveSkewMilliseconds;
	appConfig.systemTimeRoundTripMilliseconds = assessment.roundTripMilliseconds;
	appConfig.systemTimeUncertaintyMilliseconds = assessment.uncertaintyMilliseconds;

	if (assessment.validObservation) {
		appConfig.systemTimeRemoteReferenceUtc = assessment.remoteServiceTimeUtc;
		appConfig.systemTimeLocalEstimateUtc = assessment.estimatedLocalTimeUtc;

		// Establish a wall-clock/monotonic baseline at the end of the request. A later
		// discontinuity invalidates this observation and forces fresh remote validation
		// before timestamp-sensitive work is allowed to proceed.
		appConfig.systemTimeBaselineRealtimeUtc = probe.responseEndUtc;
		appConfig.systemTimeBaselineMonotonic = probe.responseEndMonotonic;
		appConfig.systemTimeBaselineValid = true;
		appConfig.systemTimeRevalidationRequired = false;

		if (assessment.state == SystemTimeState.blocking) {
			appConfig.systemTimeSyncBlocked = true;
		} else if (assessment.canClearExistingBlock) {
			// Only a fresh, valid, genuinely non-blocking external observation may
			// clear a previously-latched time block. An unconfirmed blocking sample
			// that was downgraded to warning is deliberately not sufficient.
			appConfig.systemTimeSyncBlocked = false;
		}
	}
	// TIME_AUTHORITY_UNAVAILABLE intentionally does not clear an existing block
	// or a pending revalidation requirement.
}

private string formatSignedSeconds(long milliseconds) {
	return format("%+.1f", cast(double) milliseconds / 1000.0);
}

private string formatUnsignedSeconds(long milliseconds) {
	return format("%.1f", cast(double) absoluteLong(milliseconds) / 1000.0);
}

private string formatRuntimeTimeValue(SysTime value) {
	return value == SysTime.min ? "not available" : value.toISOExtString();
}

// Explicitly place the runtime time subsystem in a disabled state. This is a
// user-requested bypass of the clock safety gate only; Microsoft connectivity
// probing remains active elsewhere in the application.
private TimeAssessment markSystemTimeCheckDisabled(ApplicationConfig appConfig, bool displayMessages) {
	TimeAssessment assessment;
	assessment.state = SystemTimeState.disabled;
	assessment.reason = "disabled_by_configuration";

	appConfig.previousSystemTimeState = appConfig.systemTimeState;
	appConfig.systemTimeState = SystemTimeState.disabled;
	appConfig.systemTimeSyncBlocked = false;
	appConfig.systemTimeRevalidationRequired = false;
	appConfig.systemTimeBaselineValid = false;
	appConfig.systemTimeValidationAttemptRecorded = false;
	appConfig.systemTimeLastCheckedUtc = SysTime.min;
	appConfig.systemTimeRemoteReferenceUtc = SysTime.min;
	appConfig.systemTimeLocalEstimateUtc = SysTime.min;
	appConfig.systemTimeObservedOffsetMilliseconds = 0;
	appConfig.systemTimeEffectiveSkewMilliseconds = 0;
	appConfig.systemTimeRoundTripMilliseconds = 0;
	appConfig.systemTimeUncertaintyMilliseconds = 0;
	appConfig.systemTimeAuthority = "";
	appConfig.systemTimeStateReason = assessment.reason;

	if (displayMessages && !appConfig.systemTimeDisabledWarningDisplayed) {
		addLogEntry();
		addLogEntry("WARNING: System time validation has been disabled by configuration", ["info", "notify"]);
		addLogEntry("The OneDrive client will not verify that the local system clock agrees with Microsoft service time.");
		addLogEntry("Timestamp-related synchronisation correctness cannot be guaranteed while 'disable_time_check' is enabled.");
		addLogEntry("Microsoft service connectivity checks remain enabled.");
		addLogEntry();
		appConfig.systemTimeDisabledWarningDisplayed = true;
	}

	return assessment;
}

// Display the full runtime clock-assessment state when display_running_config is
// enabled. This is intentionally verbose: it is a diagnostic surface for users
// and support rather than a compact normal-operation status line.
void displaySystemTimeValidationDetails(ApplicationConfig appConfig) {
	if (!appConfig.getValueBool("display_running_config")) return;

	addLogEntry();
	addLogEntry("---------------- Runtime System Time Validation -----------------");
	addLogEntry("System time validation enabled               = " ~ to!string(!appConfig.getValueBool("disable_time_check")));
	addLogEntry("System time validation state                 = " ~ appConfig.getSystemTimeStateString());
	addLogEntry("System time validation reason                = " ~ appConfig.systemTimeStateReason);

	if (appConfig.getValueBool("disable_time_check")) {
		addLogEntry("System time authority                        = not used for time validation");
		addLogEntry("Local UTC estimate                           = not available");
		addLogEntry("Microsoft service UTC                        = not available");
		addLogEntry("Observed clock difference                    = not available");
		addLogEntry("Effective clock skew                         = not available");
		addLogEntry("Round-trip time                              = not applicable");
		addLogEntry("Estimated measurement uncertainty            = not applicable");
	} else {
		addLogEntry("System time authority                        = " ~ (appConfig.systemTimeAuthority.length ? appConfig.systemTimeAuthority : "not available"));
		addLogEntry("Last time validation UTC                     = " ~ formatRuntimeTimeValue(appConfig.systemTimeLastCheckedUtc));
		addLogEntry("Local UTC estimate                           = " ~ formatRuntimeTimeValue(appConfig.systemTimeLocalEstimateUtc));
		addLogEntry("Microsoft service UTC                        = " ~ formatRuntimeTimeValue(appConfig.systemTimeRemoteReferenceUtc));

		if (appConfig.systemTimeState == SystemTimeState.authorityUnavailable || appConfig.systemTimeState == SystemTimeState.unknown) {
			addLogEntry("Observed clock difference                    = not available");
			addLogEntry("Effective clock skew                         = not available");
			addLogEntry("Round-trip time                              = " ~ to!string(appConfig.systemTimeRoundTripMilliseconds) ~ " ms");
			addLogEntry("Estimated measurement uncertainty            = not available");
		} else {
			addLogEntry("Observed clock difference                    = " ~ formatSignedSeconds(appConfig.systemTimeObservedOffsetMilliseconds) ~ " seconds (local minus Microsoft)");
			addLogEntry("Effective clock skew                         = " ~ formatUnsignedSeconds(appConfig.systemTimeEffectiveSkewMilliseconds) ~ " seconds");
			addLogEntry("Round-trip time                              = " ~ to!string(appConfig.systemTimeRoundTripMilliseconds) ~ " ms");
			addLogEntry("Estimated measurement uncertainty            = +/-" ~ formatUnsignedSeconds(appConfig.systemTimeUncertaintyMilliseconds) ~ " seconds");
		}
	}

	addLogEntry("System time sync blocking active             = " ~ to!string(appConfig.systemTimeSyncBlocked));
	addLogEntry("System time revalidation required            = " ~ to!string(appConfig.systemTimeRevalidationRequired));
	addLogEntry("Time warning threshold                       = > " ~ formatUnsignedSeconds(TIME_WARNING_THRESHOLD_MS) ~ " seconds");
	addLogEntry("Time blocking threshold                      = > " ~ formatUnsignedSeconds(TIME_BLOCKING_THRESHOLD_MS) ~ " seconds (confirmed)");
	addLogEntry("Maximum accepted time-probe RTT              = " ~ formatUnsignedSeconds(TIME_MAX_ACCEPTABLE_RTT_MS) ~ " seconds");
	addLogEntry("Periodic time revalidation interval          = " ~ to!string(TIME_PERIODIC_REVALIDATION_INTERVAL_SECONDS) ~ " seconds");
	addLogEntry("-----------------------------------------------------------------");
	addLogEntry();
}

private void logTimeAssessment(ApplicationConfig appConfig, TimeAssessment assessment, SystemTimeState stateBeforeUpdate, SystemTimeState notificationStateBeforeUpdate, long effectiveSkewBeforeUpdate, bool blockBeforeUpdate, bool displayMessages) {
	if (!displayMessages) return;

	bool stateChanged = stateBeforeUpdate != appConfig.systemTimeState;
	bool blockChanged = blockBeforeUpdate != appConfig.systemTimeSyncBlocked;
	bool previousWarning = notificationStateBeforeUpdate == SystemTimeState.warning;
	bool previousSevereWarning = previousWarning && effectiveSkewBeforeUpdate > TIME_BLOCKING_THRESHOLD_MS;

	if (assessment.validObservation) {
		if (assessment.state == SystemTimeState.ok) {
			if (blockBeforeUpdate) {
				addLogEntry();
				addLogEntry("NOTICE: System clock validation has recovered; OneDrive synchronisation will resume", ["info", "notify"]);
				addLogEntry("Microsoft service time and the local system clock are now within the acceptable range.");
				addLogEntry("OneDrive synchronisation may resume.");
				addLogEntry();
			} else if (previousWarning) {
				addLogEntry();
				addLogEntry("NOTICE: Local system clock drift has returned to the acceptable range", ["info", "notify"]);
				addLogEntry("Microsoft service time and the local system clock are now within the acceptable range.");
				addLogEntry("Observed clock difference: " ~ formatSignedSeconds(assessment.signedOffsetMilliseconds) ~ " seconds (local minus Microsoft)");
				addLogEntry();
			} else if ((stateChanged || blockChanged) && debugLogging) {
				addLogEntry("System time validation result: TIME_OK; observed offset " ~ formatSignedSeconds(assessment.signedOffsetMilliseconds) ~ " seconds", ["debug"]);
			}
			return;
		}

		if (assessment.state == SystemTimeState.warning) {
			bool warningEntered = !previousWarning;
			bool warningEscalated = previousWarning && assessment.severeWarning && !previousSevereWarning;

			// Notify on entry into warning state and when an existing warning becomes an
			// unconfirmed potentially-blocking observation. Repeated observations at the
			// same severity are debug-only so long-running monitors do not flood the console or GUI.
			if (blockBeforeUpdate && blockChanged) {
				addLogEntry();
				addLogEntry("NOTICE: System clock drift is below the blocking threshold; OneDrive synchronisation will resume", ["info", "notify"]);
				addLogEntry("A system clock drift warning remains active, but timestamp-sensitive synchronisation is no longer blocked.");
				addLogEntry("Observed clock difference: " ~ formatSignedSeconds(assessment.signedOffsetMilliseconds) ~ " seconds (local minus Microsoft)");
				addLogEntry();
			} else if (appConfig.systemTimeSyncBlocked) {
				// A previously confirmed block is intentionally sticky. If a later
				// potentially-blocking observation cannot be reconfirmed, the assessment
				// may be represented as a severe warning but synchronisation must remain
				// suspended until a valid observation actually clears the block.
				if (debugLogging) {
					addLogEntry("System time assessment is warning-level but the previously confirmed TIME_DRIFT_BLOCKING state remains latched", ["debug"]);
				}
			} else if (warningEntered || warningEscalated) {
				addLogEntry();
				if (assessment.severeWarning) {
					addLogEntry("WARNING: Significant local system clock drift detected; check system time synchronisation", ["info", "notify"]);
				} else {
					addLogEntry("WARNING: Local system clock drift detected; check system time synchronisation", ["info", "notify"]);
				}
				addLogEntry("Local UTC estimate:        " ~ assessment.estimatedLocalTimeUtc.toISOExtString());
				addLogEntry("Microsoft service UTC:     " ~ assessment.remoteServiceTimeUtc.toISOExtString());
				addLogEntry("Observed clock difference: " ~ formatSignedSeconds(assessment.signedOffsetMilliseconds) ~ " seconds (local minus Microsoft)");
				addLogEntry("Round-trip time:           " ~ to!string(assessment.roundTripMilliseconds) ~ " ms");
				addLogEntry("Estimated uncertainty:     +/-" ~ formatUnsignedSeconds(assessment.uncertaintyMilliseconds) ~ " seconds");
				addLogEntry("Accurate system time is important for reliable OneDrive synchronisation and authentication.");
				addLogEntry("Check that the operating system's time synchronisation service is enabled and functioning correctly.");
				addLogEntry();
			} else if (debugLogging) {
				addLogEntry("System time remains in TIME_DRIFT_WARNING; observed offset " ~ formatSignedSeconds(assessment.signedOffsetMilliseconds) ~ " seconds", ["debug"]);
			}
			return;
		}

		if (assessment.state == SystemTimeState.blocking) {
			if (!blockBeforeUpdate && (stateChanged || blockChanged)) {
				addLogEntry();
				addLogEntry("ERROR: OneDrive synchronisation suspended because unsafe local system clock drift has been confirmed", ["info", "notify"]);
				addLogEntry("Local UTC estimate:        " ~ assessment.estimatedLocalTimeUtc.toISOExtString());
				addLogEntry("Microsoft service UTC:     " ~ assessment.remoteServiceTimeUtc.toISOExtString());
				addLogEntry("Observed clock difference: " ~ formatSignedSeconds(assessment.signedOffsetMilliseconds) ~ " seconds (local minus Microsoft)");
				addLogEntry("Round-trip time:           " ~ to!string(assessment.roundTripMilliseconds) ~ " ms");
				addLogEntry("Result:                    TIME_DRIFT_BLOCKING");
				addLogEntry("Timestamp-sensitive OneDrive synchronisation will not proceed until system time is corrected and revalidated.");
				addLogEntry();
			} else if (debugLogging) {
				addLogEntry("System time remains TIME_DRIFT_BLOCKING; observed offset " ~ formatSignedSeconds(assessment.signedOffsetMilliseconds) ~ " seconds", ["debug"]);
			}
			return;
		}
	}

	if (assessment.state == SystemTimeState.authorityUnavailable) {
		if (stateChanged && debugLogging) {
			addLogEntry("System time authority unavailable: " ~ assessment.reason, ["debug"]);
		}
	}
}

// Validate process-visible wall time against the Date header from an existing
// Microsoft service probe. A potentially blocking observation is confirmed with
// one additional independent probe before TIME_DRIFT_BLOCKING is latched.
TimeAssessment validateSystemTime(ApplicationConfig appConfig, MicrosoftServiceProbeResult initialProbe, bool confirmBlocking = true, bool displayMessages = true) {
	if (appConfig.getValueBool("disable_time_check")) {
		return markSystemTimeCheckDisabled(appConfig, displayMessages);
	}

	SystemTimeState stateBeforeUpdate = appConfig.systemTimeState;
	// A clock discontinuity temporarily moves the runtime state to
	// TIME_REVALIDATION_REQUIRED. Preserve the last meaningful time state for
	// notification decisions so a warning recovery or escalation is not lost
	// simply because revalidation occurred in between.
	SystemTimeState notificationStateBeforeUpdate = stateBeforeUpdate == SystemTimeState.revalidationRequired ?
		appConfig.previousSystemTimeState : stateBeforeUpdate;
	long effectiveSkewBeforeUpdate = appConfig.systemTimeEffectiveSkewMilliseconds;
	bool blockBeforeUpdate = appConfig.systemTimeSyncBlocked;

	TimeAssessment assessment = assessMicrosoftServiceTime(initialProbe);
	MicrosoftServiceProbeResult acceptedProbe = initialProbe;

	if (assessment.state == SystemTimeState.blocking && confirmBlocking) {
		if (debugLogging) {
			addLogEntry("Potential blocking clock skew detected; performing confirmation Microsoft service-time probe", ["debug"]);
		}

		MicrosoftServiceProbeResult confirmationProbe = probeMicrosoftService(appConfig, false);
		TimeAssessment confirmation = assessMicrosoftServiceTime(confirmationProbe);

		if (confirmation.state == SystemTimeState.blocking &&
			confirmation.validObservation &&
			sameOffsetDirection(assessment.signedOffsetMilliseconds, confirmation.signedOffsetMilliseconds) &&
			absoluteLong(assessment.signedOffsetMilliseconds - confirmation.signedOffsetMilliseconds) <= TIME_CONFIRMATION_MAX_DIFFERENCE_MS) {
			assessment = confirmation;
			assessment.blockingConfirmed = true;
			assessment.canClearExistingBlock = false;
			assessment.reason = "blocking_skew_confirmed";
			acceptedProbe = confirmationProbe;
		} else if (confirmation.validObservation && confirmation.state != SystemTimeState.blocking) {
			// The wall clock may have been corrected between the first and second
			// observations. Prefer the newer valid non-blocking sample in that case.
			assessment = confirmation;
			assessment.blockingConfirmed = false;
			assessment.canClearExistingBlock = true;
			assessment.reason = "blocking_skew_cleared_during_confirmation";
			acceptedProbe = confirmationProbe;
		} else {
			// Do not hard-block on one anomalous Date sample. Keep the first observation
			// visible as a severe warning. Crucially, this unresolved result cannot clear
			// a blocking state that was confirmed during an earlier validation cycle.
			assessment.state = SystemTimeState.warning;
			assessment.severeWarning = true;
			assessment.blockingConfirmed = false;
			assessment.canClearExistingBlock = false;
			assessment.reason = confirmation.validObservation ? "blocking_skew_not_confirmed" : "blocking_confirmation_unavailable";
		}
	}

	updateRuntimeTimeState(appConfig, assessment, acceptedProbe);
	logTimeAssessment(appConfig, assessment, stateBeforeUpdate, notificationStateBeforeUpdate, effectiveSkewBeforeUpdate, blockBeforeUpdate, displayMessages);
	return assessment;
}

// Convenience wrapper when the caller does not already have a connectivity
// probe. This deliberately uses the same Microsoft identity HEAD request rather
// than introducing a separate time service dependency.
TimeAssessment validateSystemTime(ApplicationConfig appConfig, bool displayConnectivityLogging = true, bool displayMessages = true) {
	if (appConfig.getValueBool("disable_time_check")) {
		return markSystemTimeCheckDisabled(appConfig, displayMessages);
	}

	MicrosoftServiceProbeResult probe = probeMicrosoftService(appConfig, displayConnectivityLogging);
	return validateSystemTime(appConfig, probe, true, displayMessages);
}


// Return true when a long-running process should refresh its Microsoft service
// time observation. Use monotonic time so a bad wall clock cannot suppress or
// accelerate the revalidation cadence. Failed/unavailable observations are also
// rate-limited by this timer rather than causing a tight retry loop.
bool isSystemTimeValidationDue(ApplicationConfig appConfig) {
	if (appConfig.getValueBool("disable_time_check")) return false;
	if (!appConfig.systemTimeValidationAttemptRecorded) return true;
	return (MonoTime.currTime() - appConfig.systemTimeLastValidationAttemptMonotonic) >=
		dur!"seconds"(TIME_PERIODIC_REVALIDATION_INTERVAL_SECONDS);
}

// Detect a post-validation wall-clock step without any network request. This is
// not used to decide whether the new clock is correct or incorrect; it invalidates
// the previous external observation and forces revalidation before sync proceeds.
bool detectSystemClockDiscontinuity(ApplicationConfig appConfig, bool displayMessages = true) {
	if (appConfig.getValueBool("disable_time_check")) return false;
	if (!appConfig.systemTimeBaselineValid) return false;

	auto monotonicNow = MonoTime.currTime();
	auto realtimeNow = Clock.currTime(UTC());
	auto monotonicElapsed = monotonicNow - appConfig.systemTimeBaselineMonotonic;
	auto expectedRealtime = appConfig.systemTimeBaselineRealtimeUtc + monotonicElapsed;
	long divergenceMilliseconds = (realtimeNow - expectedRealtime).total!"msecs";

	if (absoluteLong(divergenceMilliseconds) <= TIME_MAX_WALL_MONOTONIC_DIVERGENCE_MS) {
		return false;
	}

	bool wasAlreadyPending = appConfig.systemTimeRevalidationRequired;
	appConfig.previousSystemTimeState = appConfig.systemTimeState;
	appConfig.systemTimeState = SystemTimeState.revalidationRequired;
	appConfig.systemTimeRevalidationRequired = true;
	appConfig.systemTimeStateReason = "local_clock_discontinuity_detected";

	// A wall-clock discontinuity only proves that the previous external time
	// observation is stale; the clock may have just been corrected. Do not alarm
	// the user or GUI until the fresh Microsoft service-time validation establishes
	// whether the new clock is healthy, warning-level or blocking.
	if (displayMessages && !wasAlreadyPending && debugLogging) {
		addLogEntry("Local system clock changed after the last successful Microsoft time validation; forcing revalidation", ["debug"]);
		addLogEntry("Detected wall-clock change: " ~ formatSignedSeconds(divergenceMilliseconds) ~ " seconds relative to monotonic elapsed time", ["debug"]);
	}

	return true;
}
