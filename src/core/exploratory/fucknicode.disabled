import std.stdio;

void teststr(S=string)(string testname, S str)
{
    import std.uni;
    import std.algorithm: count;
    import std.range.primitives: walkLength;
    import std.conv: to;

    writeln("\n" ~ testname);
    writeln("r.length: ", str.length);
    writeln(".byCodePoint.count: ", str.byCodePoint.count);
    writeln(".byGrapheme.walkLength: ", str.byGrapheme.walkLength);
    // tested to be slower:
    //writeln(".byGrapheme.count: ", str.byGrapheme.count);

    ulong testRawLength()     { return str.length; }
    ulong testCodepointWalk() { return str.byCodePoint.walkLength; }
    ulong testGraphemeWalk()  { return str.byGrapheme.walkLength; }
    //ulong testGraphemeCount() { return str.byGrapheme.count; }

    // benchmark
    import std.datetime: benchmark, Duration;
    enum ITERATIONS = 1000;
    auto result = benchmark!(testRawLength, testCodepointWalk, testGraphemeWalk)(ITERATIONS);

    auto base = to!Duration(result[0]);
    string printMultiplier(R)(R result)
    {
        string res = ", single: " ~ to!string(to!Duration(result) / ITERATIONS);
        return res ~ ", multiplier: " ~ to!string(to!Duration(result) / base) ~ "x";
    }

    writeln("testRawArrayLength(base): ", to!Duration(result[0]));
    writeln("testCodepointWalk: ",        to!Duration(result[1]), printMultiplier(result[1]));
    writeln("testGraphemeWalk: ",         to!Duration(result[2]), printMultiplier(result[2]));
}

void main() {
    import std.uni, std.utf;

    string shortascii   = "1234";
    string shortwestern = "1ñ34";
    string shortmulti   = "r̈a⃑⊥ b⃑";
    string longmixed    = import("test_unicode.txt");
    string longwestern  = import("test_western.txt");
    string longascii    = import("test_ascii.txt");

    teststr("shortascii", shortascii);
    teststr("shortwestern", shortwestern);
    teststr("shortmulti", shortmulti);
    teststr("longmixed", longmixed);
    teststr("longwestern", longwestern);
    teststr("longascii", longascii);
}
