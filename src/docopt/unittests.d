//  D command-line interface parser that will make you smile.
//  Copyright (c) 2014, 2015 Bob Tolbert, bob@tolbert.org
//  Licensed under terms of MIT license (see LICENSE-MIT)
//
//  https://github.com/rwtolbert/docopt.d
//
//  Ported from Python to D based on:
//   - http://docopt.org


unittest {

import std.stdio;
import std.regex;
import std.array;
import std.string;
import std.algorithm;
import std.file;
import std.path;
import std.json;

import docopt;


string sortedJSON(string input) {
    string[] parts = split(input, "\n");
    if (parts.length == 1) {
        return parts[0];
    } else {
        string[] res;
        foreach(ref p; sort(parts[1..$-1])) {
            string temp = strip(replace(p, ",", ""));
            if (temp.length > 0) {
                res ~= temp;
            }
        }
        return join(res, "|");
    }
}

bool compareJSON(JSONValue expect, JSONValue result) {
    string strE = sortedJSON(expect.toPrettyString);
    string strR = sortedJSON(result.toPrettyString);
    if (strE == strR) {
        return true;
    } 
    return false;
}

class DocoptTestItem {
    private string _doc;
    private uint _index;
    private string _prog;
    private string[] _argv;
    private JSONValue _expect;
    this(string doc, uint index, string prog, string[] argv, JSONValue expect) {
        _doc = doc;
        _index = index;
        _prog = prog;
        _argv = argv;
        _expect = expect;
    }

    @property
    string doc() {
        return _doc;
    }

    bool runTest() {
        string result;
        try {
            docopt.ArgValue[string] temp = docopt.parse(_doc, _argv);
            result = prettyPrintArgs(temp);
            //writeln(result);
        } catch (DocoptArgumentError e) {
            result = "\"user-error\"";
            return (result == _expect.toPrettyString);
        } catch (Exception e) {
            writeln(e);
            return false;
        }
        JSONValue _result = parseJSON(result);

        if (compareJSON(_expect, _result)) {
            return true;
        } else {
            writeln(format("expect: %s\nresult: %s",
                           _expect, _result));
            return false;
        }
    }
}

DocoptTestItem[] splitTestCases(string raw) {
    auto pat = regex("#.*$", "m");
    auto res = replaceAll(raw, pat, "");
    if (startsWith(raw, "\"\"\"")) {
        raw = raw[3..$];
    }
    auto fixtures = split(raw, "r\"\"\"");

    DocoptTestItem[] testcases;
    foreach(uint i, fixture; fixtures[1..$]) {
        auto parts = fixture.split("\"\"\"");
        if (parts.length == 2) {
            auto doc = parts[0];
            foreach(testcase; parts[1].split("$")[1..$]) {
                auto argv_parts = strip(testcase).split("\n");
                auto expect = parseJSON(join(argv_parts[1..$], "\n"));
                auto prog_parts = argv_parts[0].split();
                auto prog = prog_parts[0];
                string[] argv = [];
                if (prog_parts.length > 1) {
                    argv = prog_parts[1..$];
                } 
                testcases ~= new DocoptTestItem(doc, i, prog, argv, expect);
            }
        }
    }
    return testcases;
}

string testfile = "test/testcases.docopt";

if (std.file.exists(testfile)) {
    auto raw = readText(testfile);

    auto testcases = splitTestCases(raw);
    uint[] passed;
    foreach(uint i, test; testcases) {
        if (test.runTest()) {
            passed ~= i;
        } else {
            writeln(i, " failed");
            writeln(test.doc);
            writeln();
        }
    }
    writeln(format("%d passed of %d run : %.1f%%",
                   passed.length, testcases.length,
                   100.0*cast(float)passed.length/cast(float)testcases.length));
    assert(passed.length == testcases.length);
}

}
