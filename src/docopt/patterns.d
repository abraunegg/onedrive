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

import argvalue;

package struct PatternMatch {
    bool status;
    Pattern[] left;
    Pattern[] collected;
    this(bool s, Pattern[] l, Pattern[] c) {
        status = s;
        foreach(pat; l) {
            left ~= pat;
        }
        foreach(pat; c) {
            collected ~= pat;
        }
    }
}

abstract class Pattern {
    override bool opEquals(Object rhs) {
       return (this.toString() == rhs.toString());
    }

    override size_t toHash() {
        return typeid(this).toHash;
    }

    abstract Pattern[] children();
    abstract void setChildren(Pattern[] children);
    abstract string name() const;
    abstract void setName(string name);
    abstract ArgValue value();
    abstract void setValue(ArgValue value);
    abstract Pattern[] flat(string[] types = null);
    abstract bool match(ref Pattern[] left, ref Pattern[] collected);

    Pattern fix() {
        fixIdentities();
        fixRepeatingArguments();
        return this;
    }

    // make pattern-tree tips point to same object if they are equal
    private Pattern fixIdentities(Pattern[] uniq = []) {
        if (uniq.length == 0) {
            foreach(pattern; flat()) {
                if (find(uniq, pattern) == []) {
                    uniq ~= pattern;
                }
            }
        }
        foreach(i, ref child; children()) {
            if (!cast(BranchPattern)child) {
                auto place = find(uniq, child);
                assert(place != []);
                child = place[0];
            } else {
                child.fixIdentities(uniq);
            }
        }
        return this;
    }

    private Pattern fixRepeatingArguments() {
        Pattern[][] either;
        foreach(i, child; transform(this).children()) {
            if (child.children !is null) {
                Pattern[] temp;
                foreach(c; child.children) {
                    temp ~= c;
                }
                either ~= temp;
            }
        }
        foreach(item; either) {
            foreach(i, child; item) {
                if (count(item, child) > 1) {
                    if (typeid(child) == typeid(Argument) || (typeid(child) == typeid(Option) && (cast(Option)child)._argCount>0)) {
                        if (child.value.isNull) {
                            string[] temp;
                            child.setValue(new ArgValue(temp));
                        } else if (!child.value.isList) {
                            child.setValue(new ArgValue(split(child.value.toString)));
                        }
                    }
                    if (typeid(child) == typeid(Command) || (typeid(child) == typeid(Option) && (cast(Option)child)._argCount==0)) {
                        child.setValue(new ArgValue(0));
                    }
                }
            }
        }
        return this;
    }
}

private Pattern transform(Pattern pattern) {
    Pattern[][] result;
    Pattern[][] groups = [[pattern]];

    TypeInfo[] parents = [typeid(Required), typeid(Optional),
                          typeid(OptionsShortcut), typeid(Either),
                          typeid(OneOrMore)];

    while (groups.length > 0) {
        Pattern[] children = groups[0];
        groups = groups[1..$];

        bool any = false;
        foreach(c; children) {
            if (find(parents, typeid(c)) != []) {
                any = true;
            }
        }

        if (any) {
            Pattern[] currentChildren;
            foreach(c; children) {
                if (find(parents, typeid(c)) != []) {
                    currentChildren ~= c;
                }
            }
            assert(currentChildren.length > 0);

            Pattern child = currentChildren[0];
            children = removeChild(children, child);
            if (typeid(child) == typeid(Either)) {
                foreach(e; child.children) {
                    groups ~= [e] ~ children;
                }
            }
            else if (typeid(child) == typeid(OneOrMore)) {
                groups ~= child.children ~ child.children ~ children;
            }
            else {
                groups ~= child.children ~ children;
            }
        } else {
            result ~= children;
        }
    }
    Pattern[] required;
    foreach(e; result) {
        required ~= new Required(e);
    }
    return new Either(required);
}


class LeafPattern : Pattern {
    string _name = null;
    ArgValue _value = null;

    this(in string name, ArgValue value = new ArgValue()) {
        _name = name.dup;
        _value = value;
    }

    override string name() const {
        return _name;
    }

    override ArgValue value() {
        return _value;
    }

    override void setName(string name) {
        _name = name;
    }

    override void setValue(ArgValue value) {
        if (value !is null) {
            _value = value;
        } else {
            _value = null;
        }
    }

    override string toString() {
        return format("%s(%s, %s)", "LeafPattern", _name, _value.toString);
    }

    override Pattern[] flat(string[] types = null) {
        if (types is null || canFind(types, typeid(this).toString)) {
            return [this];
        }
        return [];
    }

    override bool match(ref Pattern[] left, ref Pattern[] collected) {
        uint pos = uint.max;
        auto match = singleMatch(left, pos);

        if (match is null) {
            return false;
        }
        assert(pos < uint.max);

        Pattern[] left_ = left[0..pos] ~ left[pos+1..$];

        Pattern[] sameName;
        foreach(item; collected) {
            if (item.name == name) {
                sameName ~= item;
            }
        }

        if (_value.isInt || _value.isList) {
            if (_value.isInt) {
                int increment = 1;
                if (sameName.length == 0) {
                    match.setValue(new ArgValue(increment));
                    collected ~= match;
                    left = left_;
                    return true;
                } else {
                    sameName[0].value.add(increment);
                }
            }

            // deal with lists
            if (_value.isList) {
                string [] increment;
                if (match.value.isString) {
                    increment = [match.value.toString];
                } else {
                    increment = match.value.asList;
                }
                if (sameName.length == 0) {
                    match.setValue(new ArgValue(increment));
                    collected ~= match;
                    left = left_;
                    return true;
                } else {
                    sameName[0].value.add(increment);
                }
            }
            left = left_;
            return true;
        }

        collected ~= match;
        left = left_;
        return true;
    }

    abstract Pattern singleMatch(Pattern[] left, ref uint pos);

    // not used in LeafPatterns
    override Pattern[] children() {
        return null;
    }
    override void setChildren(Pattern[] children) {
    }

}

class Option : LeafPattern {
    string _shortArg;
    string _longArg;
    uint _argCount;

    this(in string s, in string l, in uint ac=0, ArgValue v = new ArgValue(false) ) {
        if (l !is null) {
            super(l, v);
        } else {
            super(s, v);
        }
        _shortArg = s.dup;
        _longArg = l.dup;
        _argCount = ac;
        if (v.isFalse && ac>0) {
            _value = new ArgValue();
        } else {
            _value = v;
        }
    }

    override const string name() {
        if (_longArg !is null) {
            return _longArg;
        } else {
            return _shortArg;
        }
    }

    override string toString() {
        string s = "None";
        if (_shortArg !is null) {
            s = format("'%s'", _shortArg);
        }
        string l = "None";
        if (_longArg !is null) {
            l = format("'%s'", _longArg);
        }

        if (_value.isNull) {
            return format("Option(%s, %s, %s, null)", s, l, _argCount);
        } else {
            return format("Option(%s, %s, %s, %s)", s, l, _argCount, _value);
        }
    }

    string toSimpleString() {
        if (_longArg !is null) {
            return _longArg;
        } else {
            return _shortArg;
        }
    }

    override Pattern singleMatch(Pattern[] left, ref uint pos) {
        foreach (uint i, pat; left) {
            if (name == pat.name) {
                pos = i;
                return pat;
            }
        }
        pos = uint.max;
        return null;
    }
}

class BranchPattern : Pattern {
    Pattern[] _children;

    protected this() {
    }

    this(Pattern[] children) {
        _children = children;
    }

    this(Pattern child) {
        _children = [child];
    }

    override Pattern[] children() {
        return _children;
    }

    override void setChildren(Pattern[] children) {
        _children = children;
    }

    override string toString() {
        string[] childNames;
        foreach(child; _children) {
            childNames ~= child.toString();
        }
        return format("BranchPattern(%s)", join(childNames, ", "));
    }

    override Pattern[] flat(string[] types = null) {
        if (canFind(types, typeid(this).toString)) {
            return [this];
        }
        Pattern[] res;
        foreach(child; _children) {
            res ~= child.flat(types);
        }
        return res;
    }

    // not used in BranchPatterns
    override string name() const {
        return "branch";
    }
    override void setName(string name) {
    }
    override ArgValue value() const {
        return null;
    }
    override void setValue(ArgValue value) {
    }
}

Pattern[] removeChild(Pattern[] arr, Pattern child) {
    Pattern[] result;
    bool found = false;
    foreach(pat; arr) {
        if(found || pat != child) {
            result ~= pat;
        }
        if (pat == child) {
            found = true;
        }
    }
    return result;
}

class Argument : LeafPattern {
    this(string name, ArgValue value) {
        super(name, value);
    }

    this(string source) {
        auto namePat = regex(r"(<\S*?>)");
        auto match = matchAll(source, namePat);
        string name = "";
        if (!match.empty()) {
            name = match.captures[0];
        }
        auto valuePat = regex(r"\[default: (.*)\]", "i");
        match = matchAll(source, valuePat);
        string value = null;
        if (!match.empty()) {
            value = match.captures[0];
        }
        super(name, new ArgValue(value));
    }

    override Pattern singleMatch(Pattern[] left, ref uint pos) {
        foreach(uint i, pattern; left) {
            if (typeid(pattern) == typeid(Argument)) {
                pos = i;
                return new Argument(name, pattern.value);
            }
        }
        pos = uint.max;
        return null;
    }

    override string toString() {
        string temp = _value.toString;
        if (temp is null) {
            temp = "None";
        }
        string n = format("'%s'", _name);
        return format("Argument(%s, %s)", n, temp);
    }
}

class Command : Argument {
    this(string name, ArgValue value) {
        super(name, value);
    }
    this(string source) {
        super(source, new ArgValue(false));
    }
    override Pattern singleMatch(Pattern[] left, ref uint pos) {
        foreach(uint i, pattern; left) {
            if (typeid(pattern) == typeid(Argument)) {
                if (pattern.value.toString == name) {
                    pos = i;
                    return new Command(name, new ArgValue(true));
                } else {
                    break;
                }
            }
        }
        pos = uint.max;
        return null;
    }
    override string toString() {
        return format("Command(%s, %s)", _name, _value);
    }
}

class Required : BranchPattern {
    this(Pattern[] children) {
        super(children);
    }
    this(Pattern child) {
        super(child);
    }
    override bool match(ref Pattern[] left, ref Pattern[] collected) {
        auto l = left;
        auto c = collected;
        foreach(child; _children) {
            bool res = child.match(l, c);
            if (!res) {
                return false;
            }
        }
        left = l;
        collected = c;
        return true;
    }

    override string toString() {
        string[] childNames;
        foreach(child; _children) {
            childNames ~= child.toString();
        }
        return format("Required(%s)", join(childNames, ", "));
    }
}

class Optional : BranchPattern {
    this(Pattern[] children) {
        super(children);
    }
    this(Pattern child) {
        super(child);
    }
    override bool match(ref Pattern[] left, ref Pattern[] collected) {
        foreach(child; _children) {
            auto res = child.match(left, collected);
        }
        return true;
    }
    override string toString() {
        string[] childNames;
        foreach(child; _children) {
            childNames ~= child.toString();
        }
        return format("Optional(%s)", join(childNames, ", "));
    }
}

class OptionsShortcut : Optional {
    this() {
        super([]);
    }
    this(Pattern[] children) {
        super(children);
    }
    this(Pattern child) {
        super(child);
    }

    override string toString() {
        string[] childNames;
        foreach(child; _children) {
            childNames ~= child.toString();
        }
        return format("OptionsShortcut(%s)", join(childNames, ", "));
    }
}

class OneOrMore : BranchPattern {
    this(Pattern[] children) {
        super(children);
    }
    this(Pattern child) {
        super(child);
    }
    override bool match(ref Pattern[] left, ref Pattern[] collected) {
        assert(_children.length == 1);

        Pattern[] c = collected;
        Pattern[] l = left;
        Pattern[] _l = null;

        bool matched = true;
        uint times = 0;
        while (matched) {
            matched = _children[0].match(l, c);
            if (matched) {
                times += 1;
            }
            if (_l == l) {
                break;
            }
            _l = l;
        }
        if (times >= 1) {
            left = l;
            collected = c;
            return true;
        }
        return false;
    }

    override string toString() {
        string[] childNames;
        foreach(child; _children) {
            childNames ~= child.toString();
        }
        return format("OneOrMore(%s)", join(childNames, ", "));
    }
}

class Either : BranchPattern {
    this(Pattern[] children) {
        super(children);
    }
    this(Pattern child) {
        super(child);
    }

    override bool match(ref Pattern[] left, ref Pattern[] collected) {
        PatternMatch res = PatternMatch(false, left, collected);
        PatternMatch[] outcomes;
        foreach(child; _children) {
            auto l = left;
            auto c = collected;
            auto matched = child.match(l, c);
            if (matched) {
                outcomes ~= PatternMatch(matched, l, c);
            }
        }
        if (outcomes.length > 0) {
            auto minLeft = ulong.max;
            foreach (m; outcomes) {
                if (m.left.length < minLeft) {
                    minLeft = m.left.length;
                    res = m;
                }
            }
            collected = res.collected;
            left = res.left;
            return res.status;
        }
        return false;
    }
    override string toString() {
        string[] childNames;
        foreach(child; _children) {
            childNames ~= child.toString();
        }
        return format("Either(%s)", join(childNames, ", "));
    }
}

Option parseOption(string optionDescription) {
    string shortArg = null;
    string longArg = null;
    uint argCount = 0;
    string value = "false";

    auto parts = split(strip(optionDescription), "  ");
    string options = parts[0];
    string description = "";
    if (parts.length > 1) {
        description = join(parts[1..$], " ");
    }
    options = replace(options, ",", " ");
    options = replace(options, "=", " ");
    foreach(s; split(options)) {
        if (startsWith(s, "--")) {
            longArg = s;
        } else if (startsWith(s, "-")) {
            shortArg = s;
        } else {
            argCount = 1;
        }
    }
    if (argCount > 0) {
        auto pat = regex(r"\[default: (.*)\]", "i");
        auto match = matchAll(description, pat);
        if (!match.empty()) {
            value = match.captures[1];
        } else {
            value = null;
        }
    }

    if (value == "false") {
        return new Option(shortArg, longArg, argCount, new ArgValue(false));
    } else if (value is null) {
        return new Option(shortArg, longArg, argCount, new ArgValue());
    } else {
        return new Option(shortArg, longArg, argCount, new ArgValue(value));
    }
}



unittest {

    // Options
    assert(parseOption("-h") == new Option("-h", null));
    assert(parseOption("--help") == new Option(null, "--help"));
    assert(parseOption("-h --help") == new Option("-h", "--help"));
    assert(parseOption("-h, --help") == new Option("-h", "--help"));
    assert(parseOption("-h TOPIC") == new Option("-h", null, 1));
    assert(parseOption("--help TOPIC") == new Option(null, "--help", 1));
    assert(parseOption("-h TOPIC --help TOPIC") == new Option("-h", "--help", 1));
    assert(parseOption("-h TOPIC, --help TOPIC") == new Option("-h", "--help", 1));
    assert(parseOption("-h TOPIC, --help=TOPIC") == new Option("-h", "--help", 1));

    assert(parseOption("-h  Description...") == new Option("-h", null));
    assert(parseOption("-h --help  Description...") == new Option("-h", "--help"));
    assert(parseOption("-h TOPIC  Description...") == new Option("-h", null, 1));

    assert(parseOption("    -h") == new Option("-h", null));

    assert(parseOption("-h TOPIC  Descripton... [default: 2]") == 
           new Option("-h", null, 1, new ArgValue("2")));
    assert(parseOption("-h TOPIC  Descripton... [default: topic-1]") == 
           new Option("-h", null, 1, new ArgValue("topic-1")));
    assert(parseOption("--help=TOPIC  ... [default: 3.14]") == 
           new Option(null, "--help", 1, new ArgValue("3.14")));
    assert(parseOption("-h, --help=DIR  ... [default: ./]") == 
           new Option("-h", "--help", 1, new ArgValue("./")));
    assert(parseOption("-h TOPIC  Descripton... [dEfAuLt: 2]") == 
           new Option("-h", null, 1, new ArgValue("2")));

    assert(parseOption("-h").name == "-h");
    assert(parseOption("-h --help").name == "--help");
    assert(parseOption("--help").name == "--help");

}
