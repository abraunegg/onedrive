import std.stdio;

// enable verbose logging
bool verbose;

void log(T...)(T args)
{
	stderr.writeln(args);
}

void vlog(T...)(T args)
{
	if (verbose) stderr.writeln(args);
}
