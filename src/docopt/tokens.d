//  D command-line interface parser that will make you smile.
//  Copyright (c) 2014 Bob Tolbert, bob@tolbert.org
//  Licensed under terms of MIT license (see LICENSE-MIT)
//
//  https://github.com/rwtolbert/docopt.d
//
//  Ported from Python to D based on:
//   - http://docopt.org


import std.string;
import std.regex;
import std.array;

class Tokens {
    string[] _list;
    bool _isParsingArgv;
    this(string[] source, bool parsingArgv = true) {
        _list ~= source;
        _isParsingArgv = parsingArgv;
    }
    this(string source, bool parsingArgv = true) {
        auto pat = regex(r"([\[\]\(\)\|]|\.\.\.)");
        string newSource = replaceAll(source, pat, r" $1 ");
        auto splitPat = regex(r"\s+|(\S*<.*?>)");
        auto parts = split(newSource, splitPat);
        auto match = array(matchAll(newSource, splitPat));
        auto l = parts.length;
        for(auto i = 0; i < l; i++) {
            if (parts[i].length > 0) {
                _list ~= parts[i];
            }
            if (i < l-1 && match[i][1].length > 0) {
                _list ~= match[i][1];
            }
        }
        _isParsingArgv = parsingArgv;
    }

    @property
    bool isParsingArgv() {
        return _isParsingArgv;
    }

    string move() {
        if (_list.length > 0) {
            string res = _list[0].dup;
            _list = _list[1..$];
            return res;
        } else {
            return null;
        }
    }
    string current() {
        if (_list.length > 0) {
            return _list[0].dup;
        } else {
            return null;
        }
    }
}

