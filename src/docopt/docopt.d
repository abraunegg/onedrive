//  D command-line interface parser that will make you smile.
//  Copyright (c) 2014, 2015 Bob Tolbert, bob@tolbert.org
//  Licensed under terms of MIT license (see LICENSE-MIT)
//
//  https://github.com/rwtolbert/docopt.d
//
//  Ported from Python to D based on:
//   - http://docopt.org

import std.stdio;
import std.regex;
import std.string;
import std.array;
import std.algorithm;
import std.container;
import std.traits;
import std.ascii;
import std.conv;
import core.stdc.stdlib;
import std.json;

private import argvalue;
private import patterns;
private import tokens;

class DocoptLanguageError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

class DocoptArgumentError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

class TokensOptionError : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

class DocoptExitHelp : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

class DocoptExitVersion : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

private Option[] parseDefaults(string doc) {
    Option[] defaults;
    foreach(sect; parseSection("options:", doc)) {
        auto s = sect[std.string.indexOf(sect, ":")+1..$];
        auto pat = regex(r"\n[ \t]*(-\S+?)");
        auto parts = split("\n"~s, pat)[1..$];
        auto match = array(matchAll("\n"~s, pat));
        foreach(i, m; match) {
            string optionDescription = m[1] ~ parts[i];
            if (startsWith(optionDescription, "-")) {
                defaults ~= parseOption(optionDescription);
            }
        }
    }
    return defaults;
}

private string[] parseSection(string name, string doc) {
    string[] res;
    auto p = regex("^([^\n]*" ~ name ~ "[^\n]*\n?(?:[ \t].*?(?:\n|$))*)", "im");
    auto match = array(matchAll(doc, p));
    foreach (i, m; match) {
        res ~= strip(m[0]);
    }
    return res;
}

private string formalUsage(string section) {
    auto s = section[std.string.indexOf(section, ":")+1..$];
    auto parts = split(s);
    string[] subs;
    foreach(part; parts[1..$]) {
        if (part == parts[0]) {
            subs ~= ") | (";
        } else {
            subs ~= part;
        }
    }
    return "( " ~ join(subs, " ") ~ " )";
}

private Pattern[] parseLong(Tokens tokens, ref Option[] options) {
    auto parts = tokens.move().split("=");
    string longArg = parts[0];
    assert(startsWith(longArg, "--"));
    string value;

    if (parts.length > 1) {
        value = parts[1];
    }

    Option[] similar;
    foreach (o; options) {
        if (o._longArg == longArg) {
            similar ~= o;
        }
    }

    if (tokens.isParsingArgv && similar.length == 0) {
        foreach (o; options) {
            if (o._longArg && startsWith(o._longArg, longArg)) {
                similar ~= o;
            }
        }
    }

    Option o;

    if (similar.length > 1) {
        auto msg = format("%s is not a unique prefix: %s?", longArg, similar);
        throw new TokensOptionError(msg);
    } else if (similar.length < 1) {
        uint argCount = 0;
        if (parts.length > 1) {
            argCount = 1;
        }
        o = new Option(null, longArg, argCount);
        options = options ~ o;

        if (tokens.isParsingArgv) {
            if (value.length == 0) {
                o = new Option(null, longArg, argCount, new ArgValue(true));
            } else {
                o = new Option(null, longArg, argCount, new ArgValue(value));
            }
        }
    } else {
        o = new Option(similar[0]._shortArg, similar[0]._longArg, similar[0]._argCount, similar[0]._value);
        if (o._argCount == 0) {
            if (value.length != 0) {
                auto msg = format("%s must not have an argument.", o._longArg); 
                throw new TokensOptionError(msg);
            }
        } else {
            if (value.length == 0) {
                if (tokens.current().length == 0 || tokens.current() == "--") {
                    auto msg = format("%s requires argument.", o._longArg);
                    throw new TokensOptionError(msg);
                }
                value = tokens.move();
            }
        }
        if (tokens.isParsingArgv) {
            if (value.length == 0) {
                o.setValue(new ArgValue(true));
            } else {
                o.setValue(new ArgValue(value));
            }
        }
    }
    return [o];
}

private Pattern[] parseShort(Tokens tokens, ref Option[] options) {
    string token = tokens.move();
    assert(startsWith(token, "-") && !startsWith(token, "--"));
    string left = stripLeft(token, '-');

    Pattern[] parsed;
    while (left != "") {
        string shortArg = "-" ~ left[0];
        left = left[1..$];

        Option[] similar;
        foreach (o; options) {
            if (o._shortArg == shortArg) {
                similar ~= o;
            }
        }
        Option o;
        if (similar.length > 1) {
            string msg = format("%s is specified ambiguously %d times", shortArg, similar.length);
            throw new TokensOptionError(msg);
        } else if (similar.length < 1) {
            o = new Option(shortArg, null, 0);
            options ~= o;
            if (tokens.isParsingArgv) {
                o = new Option(shortArg, null, 0, new ArgValue(true));
            }
        } else {
            o = new Option(shortArg, similar[0]._longArg, similar[0]._argCount, similar[0]._value);
            string value;
            if (o._argCount != 0) {
                if (left == "") {
                    if (tokens.current.length == 0 || tokens.current == "--") {
                        string msg = format("%s requires an argument", shortArg);
                        throw new TokensOptionError(msg);
                    }
                    value = tokens.move();
                } else {
                    value = left;
                    left = "";
                }
            }
            if (tokens.isParsingArgv) {
                if (value.length == 0) {
                    o.setValue(new ArgValue(true));
                } else {
                    o.setValue(new ArgValue(value));
                }
            }
        }
        parsed ~= o;
    }

    return parsed;
}

private Pattern parsePattern(string source, ref Option[] options) {
    auto tokens = new Tokens(source, false);
    Pattern[] result = parseExpr(tokens, options);
    if (tokens.current().length != 0) {
        string msg = format("unexpected ending: %s", tokens.toString());
        throw new DocoptLanguageError(msg);
    }
    return new Required(result);
}

private Pattern[] parseExpr(Tokens tokens, ref Option[] options) {
    Pattern[] seq = parseSeq(tokens, options);
    if (tokens.current() != "|") {
        return seq;
    }
    Pattern[] result;
    if (seq.length > 1) {
        result = [new Required(seq)];
    } else {
        result = seq;
    }
    while (tokens.current() == "|") {
        tokens.move();
        seq = parseSeq(tokens, options);
        if (seq.length > 1) {
            result ~= new Required(seq);
        } else {
            result ~= seq;
        }
    }

    if (result.length > 1) {
        return [new Either(result)];
    }

    return result;
}

private Pattern[] parseSeq(Tokens tokens, ref Option[] options) {
    Pattern[] result;
    string seps = "])|";
    while (!canFind(seps, tokens.current())) {
        Pattern[] atom = parseAtom(tokens, options);
        if (tokens.current() == "...") {
            atom = [new OneOrMore(atom)];
            tokens.move();
        }
        result ~= atom;
    }
    return result;
}

private bool isUpperString(string s) {
    foreach (c; s) {
        if (!isUpper(c)) {
            return false;
        }
    }
    return true;
}

private Pattern[] parseAtom(Tokens tokens, ref Option[] options) {
    string token = tokens.current();
    Pattern[] result;
    string matching;
    Pattern pat;

    if (token == "(" || token == "[") {
        tokens.move();
        if (token == "(") {
            matching = ")";
            pat = new Required(parseExpr(tokens, options));
        } else {
            matching = "]";
            pat = new Optional(parseExpr(tokens, options));
        }
        if (tokens.move() != matching) {
            writeln("big fail");
            assert(false);
        }
        return [pat];
    } else if (token == "options") {
        tokens.move();
        return [new OptionsShortcut()];
    } else if (startsWith(token, "--") && token != "--") {
        return parseLong(tokens, options);
    } else if (startsWith(token, "-") && token != "-" && token != "--") {
        return parseShort(tokens, options);
    } else if ((startsWith(token, "<") && endsWith(token, ">")) || isUpperString(token)) {
        return [new Argument(tokens.move(), new ArgValue())];
    } else {
        return [new Command(tokens.move())];
    }
}

private Pattern[] parseArgv(Tokens tokens, ref Option[] options, bool optionsFirst=false) {
    Pattern[] parsed;

    while (tokens.current.length != 0) {
        if (tokens.current == "--") {
            foreach(tok; tokens._list) {
                parsed ~= new Argument(null, new ArgValue(tok));
            }
            return parsed;
        } else if (startsWith(tokens.current, "--")) {
            parsed ~= parseLong(tokens, options);
        } else if (startsWith(tokens.current, "-") && tokens.current != "-") {
            parsed ~= parseShort(tokens, options);
        } else if (optionsFirst) {
            foreach(tok; tokens._list) {
                parsed ~= new Argument(null, new ArgValue(tok));
            }
            return parsed;
        } else {
            parsed ~= new Argument(null, new ArgValue(tokens.move()));
        }
    }

    return parsed;
}


private void extras(bool help, string vers, Pattern[] args) {
    if (help) {
        foreach(opt; args) {
            if ( (opt.name == "-h" || opt.name == "--help") && opt.value) {
                throw new DocoptExitHelp("help");
            }
        }
    }
    if (vers.length != 0) {
        foreach(opt; args) {
            if (opt.name == "--version" && opt.value !is null) {
                throw new DocoptExitVersion("version");
            }
        }
    }
}

Pattern[] subsetOptions(Option[] docOptions, Pattern[] patternOptions) {
    Pattern[] res;
    res ~= docOptions;
    foreach(p; patternOptions) {
        if (canFind(res, p)) {
            res = removeChild(res, p);
        }
    }
    return res;
}

public ArgValue[string] parse(string doc, string[] argv,
                               bool help = true,
                               string vers = "",
                               bool optionsFirst = false) {
    ArgValue[string] dict;

    auto usageSections = parseSection("usage:", doc);
    if (usageSections.length == 0) {
        throw new DocoptLanguageError("'usage:' (case-insensitive) not found.");
    }
    if (usageSections.length > 1) {
        throw new DocoptLanguageError("More than one 'usage:' (case-insensitive)");
    }
    auto usageMsg = usageSections[0];
    auto formal = formalUsage(usageMsg);

    Pattern pattern;
    Option[] options;
    try {
        options = parseDefaults(doc);
        pattern = parsePattern(formal, options);
    } catch(TokensOptionError e) {
        throw new DocoptLanguageError(e.msg);
    }

    //writeln("options ", options);
    //writeln("pattern ", pattern);

    Pattern[] args;
    try {
        args = parseArgv(new Tokens(argv), options, optionsFirst);
    } catch(TokensOptionError e) {
        throw new DocoptArgumentError(e.msg);
    }

    auto patternOptions = pattern.flat([typeid(Option).toString]);

    foreach(ref shortcut; pattern.flat([typeid(OptionsShortcut).toString])) {
        auto docOptions = parseDefaults(doc);
        shortcut.setChildren(subsetOptions(docOptions, patternOptions));
    }

    //writeln("patternOptions ", patternOptions);
    //writeln("args ", args);

    extras(help, vers, args);

    Pattern[] collected;
    bool match = pattern.fix().match(args, collected);

    //writeln("match ", match);
    //writeln("args ", args);

    if (match && args.length == 0) {
        auto fin = pattern.flat() ~ collected;
        foreach(key; fin) {
            dict[key.name] = key.value;
        }
        return dict;
    } 
    
    if (match) {
        string[] unexpected;
        foreach(arg; args) {
            unexpected ~= arg.name;
        }
        string msg = join(unexpected, ", ");
        throw new DocoptArgumentError(format("Unexpected arguments: %s", msg));
    }

    throw new DocoptArgumentError(usageMsg);
}

public ArgValue[string] docopt(string doc, string[] argv,
                               bool help = true,
                               string vers = "",
                               bool optionsFirst = false)
{
    try {
        return parse(doc, argv, help, vers, optionsFirst);
    } catch(DocoptExitHelp) {
        writeln(doc);
        exit(0);
    } catch(DocoptExitVersion) {
        writeln(vers);
        exit(0);
    } catch(DocoptLanguageError e) {
        writeln("docopt usage string parse failure");
        writeln(e.msg);
        exit(-1);
    } catch(DocoptArgumentError e) {
        writeln(e.msg);
        exit(-1);
    }
    assert(0);
}

private string prettyArgValue(ArgValue[string] dict) {
    string ret = "{";
    bool first = true;
    foreach(key, val; dict) {
        if (first)
            first = false;
        else
            ret ~= ",";

        ret ~= format("\"%s\"", key);
        ret ~= ":";
        if (val.isBool) {
            ret ~= val.toString;
        } else if (val.isInt) {
            ret ~= val.toString;
        } else if (val.isNull) {
            ret ~= "null";
        } else if (val.isList) {
            ret ~= "[";
            bool firstList = true;
            foreach(str; val.asList) {
                if (firstList)
                    firstList = false;
                else
                    ret ~= ",";
                ret ~= format("\"%s\"", str);
            }
            ret ~= "]";
        } else {
            ret ~= format("\"%s\"", val.toString);
        }
    }
    ret ~= "}";
    return ret;
}

public string prettyPrintArgs(ArgValue[string] args) {
    JSONValue result = parseJSON(prettyArgValue(args));
    return result.toPrettyString;
}

version(unittest)
{
    Tokens TS(string toks, bool parsingArgv = true) {
        return new Tokens(toks, parsingArgv);
    }
}

unittest {
    // Commands
    ArgValue[string] empty;
    assert(docopt("Usage: prog", []) == empty);
    assert(docopt("Usage: prog add", ["add"]) == ["add": new ArgValue(true)]);
    assert(docopt("Usage: prog [add]", [""]) == ["add": new ArgValue(false)]);
    assert(docopt("Usage: prog [add]", ["add"]) == ["add": new ArgValue(true)]);
    assert(docopt("Usage: prog (add|rm)", ["add"]) == ["add": new ArgValue(true), "rm": new ArgValue(false)]);
    assert(docopt("Usage: prog (add|rm)", ["rm"]) == ["add": new ArgValue(false), "rm": new ArgValue(true)]);
    assert(docopt("Usage: prog a b", ["a", "b"]) == ["a": new ArgValue(true), "b": new ArgValue(true)]);

    // formal usage
    auto doc = "
Usage: prog [-hv] ARG
       prog N M

prog is a program.
";
    auto usageStr = parseSection("usage:", doc);
    assert(usageStr[0] ==  "Usage: prog [-hv] ARG\n       prog N M");
    assert(formalUsage(usageStr[0]) == "( [-hv] ARG ) | ( N M )");

    // test parseArgv
    auto o = [new Option("-h", null), 
              new Option("-v", "--verbose"),
              new Option("-f", "--file", 1)];
    assert(parseArgv(TS(""), o) == []);
    assert(parseArgv(TS("-h"), o) == [new Option("-h", null, 0, new ArgValue(true))]);
    assert(parseArgv(TS("-h --verbose"), o) == 
           [new Option("-h", null, 0, new ArgValue(true)), 
            new Option("-v", "--verbose", 0, new ArgValue(true))]);
    assert(parseArgv(TS("-h --file f.txt"), o) == 
           [new Option("-h", null, 0, new ArgValue(true)), 
            new Option("-f", "--file", 1, new ArgValue("f.txt"))]);

    Pattern[] correct;    
    correct ~= new Option("-h", null, 0, new ArgValue(true));
    correct ~= new Option("-f", "--file", 1, new ArgValue("f.txt"));
    correct ~= new Argument(null, new ArgValue("arg"));
    assert(parseArgv(TS("-h --file f.txt arg"), o) == correct);

    correct.destroy();
    correct ~= new Option("-h", null, 0, new ArgValue(true));
    correct ~= new Option("-f", "--file", 1, new ArgValue("f.txt"));
    correct ~= new Argument(null, new ArgValue("arg"));
    correct ~= new Argument(null, new ArgValue("arg2"));
    assert(parseArgv(TS("-h --file f.txt arg arg2"), o) == correct);

    correct.destroy();
    correct ~= new Option("-h", null, 0, new ArgValue(true));
    correct ~= new Argument(null, new ArgValue("arg"));
    correct ~= new Argument(null, new ArgValue("--"));
    correct ~= new Argument(null, new ArgValue("-v"));
    assert(parseArgv(TS("-h arg -- -v"), o) == correct);

    // parsePattern
    assert(parsePattern("[ -h ]", o) == new Required(new Optional(new Option("-h", null))));
    assert(parsePattern("[ ARG ... ]", o) == 
           new Required(new Optional(new OneOrMore(new Argument("ARG", new ArgValue())))));

    assert(parsePattern("[ -h | -v ]", o) == 
           new Required(new Optional(new Either([new Option("-h", null),
                                                 new Option("-v", "--verbose")]))));
    Pattern[] temp1;
    temp1 ~= new Option("-v", "--verbose");
    temp1 ~= new Optional(new Option("-f", "--file", 1, new ArgValue(false)));
    Pattern[] temp2;
    temp2 ~= new Option("-h", null);
    temp2 ~= new Required(temp1);
    assert(parsePattern("( -h | -v [ --file <f> ] )", o) == 
           new Required(new Required(new Either(temp2))));

    //assert(parsePattern("(-h|-v[--file=<f>]N...)", options=o) == \
    //                Required(Required(Either(Option("-h"),
    //                                         Required(Option("-v", "--verbose"),
    //                                                  Optional(Option("-f", "--file", 1, None)),
    //                                                  OneOrMore(Argument("N"))))))
    //assert(parsePattern("(N [M | (K | L)] | O P)", options=[]) == \
    //                    Required(Required(Either(
    //                                             Required(Argument("N"),
    //                                                      Optional(Either(Argument("M"),
    //                                                                      Required(Either(Argument("K"),
    //                                                                                      Argument("L")))))),
    //                                             Required(Argument("O"), Argument("P")))))
    //assert(parsePattern("[ -h ] [N]", options=o) == \
    //                        Required(Optional(Option("-h")),
    //                                 Optional(Argument("N")))
    //assert(parsePattern("[options]", options=o) == \
    //                            Required(Optional(OptionsShortcut()))
    //assert(parsePattern("[options] A", options=o) == \
    //                                Required(Optional(OptionsShortcut()),
    //                                         Argument("A"))
    //assert(parsePattern("-v [options]", options=o) == \
    //                                    Required(Option("-v", "--verbose"),
    //                                             Optional(OptionsShortcut()))
    //assert(parsePattern("ADD", options=o) == Required(Argument("ADD"))
    //assert(parsePattern("<add>", options=o) == Required(Argument("<add>"))
    //assert(parsePattern("add", options=o) == Required(Command("add"))

    // option match

    Option testA = parseOption("-a");
    Pattern[] pat;
    Pattern[] coll;
    Pattern[] finalPat;
    Pattern[] finalColl;
    pat ~= new Option("-a", null, 0, new ArgValue(true));
    finalColl ~= new Option("-a", null, 0, new ArgValue(true));
    assert(testA.match(pat, coll));
    assert(pat == finalPat);
    assert(coll == finalColl);

    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Option("-x", null);
    finalPat ~= new Option("-x", null);
    assert(testA.match(pat, coll) == false);
    assert(pat == finalPat);
    assert(coll == finalColl);

    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Argument("N");
    finalPat ~= new Argument("N");
    assert(testA.match(pat, coll) == false);
    assert(pat == finalPat);
    assert(coll == finalColl);

    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Option("-x", null);
    pat ~= new Option("-a", null);
    pat ~= new Argument("N");
    finalPat ~= new Option("-x", null);
    finalPat ~= new Argument("N");
    finalColl ~= new Option("-a", null);
    assert(testA.match(pat, coll) == true);
    assert(pat == finalPat);
    assert(coll == finalColl);

    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Option("-a", null, 0, new ArgValue(true));
    pat ~= new Option("-a", null);
    finalPat ~= new Option("-a", null);
    finalColl ~= new Option("-a", null, 0, new ArgValue(true));
    assert(testA.match(pat, coll) == true);
    assert(pat == finalPat);
    assert(coll == finalColl);

    // argument match
    Argument testArg = new Argument("N", new ArgValue());
    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Argument(null, new ArgValue(9));
    finalColl ~= new Argument("N", new ArgValue(9));
    assert(testArg.match(pat, coll));
    assert(pat == finalPat);
    assert(coll == finalColl);
    //assert Argument('N').match([Option('-x')]) == (False, [Option('-x')], [])
    //assert Argument('N').match([Option('-x'),
    //    Option('-a'),
    //    Argument(None, 5)]) == \
    //        (True, [Option('-x'), Option('-a')], [Argument('N', 5)])
    //assert Argument('N').match([Argument(None, 9), Argument(None, 0)]) == \
    //            (True, [Argument(None, 0)], [Argument('N', 9)])

    // command match

    Command testC = new Command("c");
    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Argument(null, new ArgValue("c"));
    finalColl ~= new Command("c", new ArgValue(true));
    assert(testC.match(pat, coll));
    assert(pat == finalPat);
    assert(coll == finalColl);

    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Option("-x", null);
    finalPat ~= new Option("-x", null);
    assert(testC.match(pat, coll) == false);
    assert(pat == finalPat);
    assert(coll == finalColl);

    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Option("-x", null);
    pat ~= new Option("-a", null);
    pat ~= new Argument(null, new ArgValue("c"));
    finalPat ~= new Option("-x", null);
    finalPat ~= new Option("-a", null);
    finalColl ~= new Command("c", new ArgValue(true));
    assert(testC.match(pat, coll));
    assert(pat == finalPat);
    assert(coll == finalColl);

    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Argument(null, new ArgValue("rm"));
    finalColl ~= new Command("rm", new ArgValue(true));
    Pattern testE = new Either([new Command("add", new ArgValue(false)),
                                new Command("rm", new ArgValue(false))]);
    assert(testE.match(pat, coll));
    assert(pat == finalPat);
    assert(coll == finalColl);

    // test optional match
    Optional testOptA = new Optional(new Option("-a", null));
    pat.destroy();
    coll.destroy();
    finalPat.destroy();
    finalColl.destroy();
    pat ~= new Option("-a", null);
    finalColl ~= new Option("-a", null);
    assert(testOptA.match(pat, coll));
    assert(pat == finalPat);
    assert(coll == finalColl);


    //assert Optional(Option('-a')).match([Option('-a')]) == \
    //    (True, [], [Option('-a')])

    //assert Optional(Option('-a')).match([]) == (True, [], [])
    //assert Optional(Option('-a')).match([Option('-x')]) == \
    //            (True, [Option('-x')], [])
    //assert Optional(Option('-a'), Option('-b')).match([Option('-a')]) == \
    //                (True, [], [Option('-a')])
    //assert Optional(Option('-a'), Option('-b')).match([Option('-b')]) == \
    //                    (True, [], [Option('-b')])
    //assert Optional(Option('-a'), Option('-b')).match([Option('-x')]) == \
    //                        (True, [Option('-x')], [])
    //assert Optional(Argument('N')).match([Argument(None, 9)]) == \
    //                            (True, [], [Argument('N', 9)])
    //assert Optional(Option('-a'), Option('-b')).match(
    //                    [Option('-b'), Option('-x'), Option('-a')]) == \
    //                 (True, [Option('-x')], [Option('-a'), Option('-b')])


    // test parseSection

    auto usage = "
usage: this

usage:hai
usage: this that

usage: foo
       bar

PROGRAM USAGE:
 foo
 bar
usage:
\ttoo
\ttar
Usage: eggs spam
BAZZ
usage: pit stop";

    assert(parseSection("usage:", "foo bar fizz buzz") == []);
    assert(parseSection("usage:", "usage: prog") == ["usage: prog"]);
    assert(parseSection("usage:", "usage: -x\n -y") == ["usage: -x\n -y"]);
    assert(parseSection("usage:", usage) == [
            "usage: this",
            "usage:hai",
            "usage: this that",
            "usage: foo\n       bar",
            "PROGRAM USAGE:\n foo\n bar",
            "usage:\n\ttoo\n\ttar",
            "Usage: eggs spam",
            "usage: pit stop",
        ]);


    // test any options parameter
    try {
        parse("usage: prog [options]", ["-foo", "--bar", "--spam=eggs"]);
    } catch(DocoptArgumentError) {
        assert(true);
    } catch(Exception) {
        assert(false);
    }
    try {
        parse("usage: prog [options]", ["--foo", "--bar", "--bar"]);
    } catch(DocoptArgumentError) {
        assert(true);
    } catch(Exception) {
        assert(false);
    }
    try {
        parse("usage: prog [options]", ["--bar", "--bar", "--bar", "-ffff"]);
    } catch(DocoptArgumentError) {
        assert(true);
    } catch(Exception) {
        assert(false);
    }
    try {
        parse("usage: prog [options]", ["--long=arg", "--long=another"]);
    } catch(DocoptArgumentError) {
        assert(true);
    } catch(Exception) {
        assert(false);
    }

}
