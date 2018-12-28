//  D command-line interface parser that will make you smile.
//  Copyright (c) 2014, 2015 Bob Tolbert, bob@tolbert.org
//  Licensed under terms of MIT license (see LICENSE-MIT)
//
//  https://github.com/rwtolbert/docopt.d
//
//  Ported from Python to D based on:
//   - http://docopt.org


import std.stdio;
import std.string;
import std.container;
import std.variant;
import std.conv;

public class ArgValue
{
    private Variant _value;

    @property {
        Variant value() {
            return _value;
        }
    }

    override bool opEquals(Object rhs) {
        if (typeid(this) != typeid(rhs)) {
            return false;
        }
        return (this.value == (cast(ArgValue)rhs).value);
    }

    override size_t toHash() {
        return typeid(this).toHash;
    }

    public this() {
        _value = null;
    }

    public this(in string val) {
        _value = val.dup;
    }

    public this(in string[] val) {
        _value = val.dup;
    }

	public this(int val) {
        _value = val;
	}

	public this(bool val) {
        _value = val;
	}

    bool isNull() const {
        return (_value == null);
    }

	bool isBool() const {
		return (_value.type == typeid(bool));
	}

    bool isFalse() const {
        if (isBool) {
            return (*_value.peek!(bool) == false);
        }
        return false;
    }

    bool isTrue() const {
        if (isBool) {
            return (*_value.peek!(bool) == true);
        }
        return false;
    }

    bool isInt() const {
		return (_value.type == typeid(int));
    }

    int asInt() {
        if (isInt) {
			return *_value.peek!(int);
        }
        return int.max;
    }

    bool isString() const {
		return (_value.type == typeid(char[]));
    }

    override string toString() {
        if (isList) {
			if (isEmpty) {
				return "[]";
			} else {
	            string[] res;
		        foreach(string v; asList) {
			        res ~= format("\"%s\"", v);
				}
				return "[" ~ join(res, ", ") ~ "]";
			}
        } else if (isNull) {
            return "null";
        } else {
            return _value.toString;
        }
    }

	bool isList() const {
        return (_value.type == typeid(string[]));
    }

	bool isEmpty() const {
		if (isList) {
			return (_value.peek!(string[]).length == 0);
		}
		return false;
	}

	string[] asList() {
		if (isList) {
			return *_value.peek!(string[]);
		}
		return [];
	}

    void add(string increment) {
		if (isList) {
	        *_value.peek!(string[]) ~= increment.dup;
		} else { // convert to list
            string[] res;
            res ~= _value.toString;
            res ~= increment;
            _value = res;
        }
    }

    void add(string[] increment) {
		if (isList) {
	        *_value.peek!(string[]) ~= increment.dup;
		} else { // convert to list
            string[] res;
            res ~= _value.toString;
            res ~= increment;
            _value = res;
        }
    }

    void add(int increment) {
        if (isInt) {
            _value = asInt + increment;
        }
    }
}

unittest {
    ArgValue i = new ArgValue(3);

    assert(i.isString == false);
    assert(i.isList == false);
    assert(i.isTrue == false);
    assert(i.isFalse == false);
    assert(i.isInt);
    assert(i.asInt == 3);
    i.add(1);
    assert(i.asInt == 4);

    ArgValue b = new ArgValue(true);
    assert(b.isTrue);

    ArgValue b2 = new ArgValue(false);
    assert(b2.isFalse);

    ArgValue s = new ArgValue("hello");
    assert(s.isString);
    assert(s.isList == false);
    assert(s.toString == "hello");

    s.add("world");
    assert(s.toString);
	assert(s.isList);
    assert(s.toString == "[\"hello\", \"world\"]");

    s.add(["from", "D"]);
    assert(s.toString == "[\"hello\", \"world\", \"from\", \"D\"]");

    string[] temp;
    ArgValue emptyList = new ArgValue(temp);
    assert(emptyList.isList);

    ArgValue nullVal = new ArgValue();
    assert(nullVal.isNull);
}
