import std.stdio;

// enable verbose logging
bool verbose;

void log(T...)(T args)
{
	writeln(args);
}

void vlog(T...)(T args)
{
	if (verbose) writeln(args);
}

void error(T...)(T args)
{
	stderr.writeln(args);
}