module neme.core.gapbuffer_test;

import neme.core.gapbuffer;
import std.exception: assertNotThrown, assertThrown;
import std.conv;
import std.uni: byGrapheme, byCodePoint;
import std.range: take, tail;
import std.stdio: writeln;
import std.typecons;
import std.algorithm: count;

// TODO: add fuzzy testing
// TODO add test names, or use unithreaded
// @("Like this")
debug
{
    // unittest support functions
    // TODO: use them in the grapheme support methods in GapBuffer?

    ArrayIdx firstGraphemesSize(S)(S txt, GrpmIdx n)
    {
        return txt.byGrapheme.take(n.to!long).byCodePoint.to!S.length;
    }

    ArrayIdx lastGraphemesSize(S)(S txt, GrpmIdx count)
    {
        return txt.byGrapheme.tail(count.to!long).byCodePoint.to!S.length;
    }

    ArrayIdx graphemesSizeFrom(S)(S txt, GrpmIdx from)
    {
        return txt.byGrapheme.take(from.to!long).byCodePoint.to!S.length;
    }

    S graphemeSlice(S, T = string)(S txt, GrpmIdx from, T to)
    {
        ArrayIdx startArrayIdx = txt.firstGraphemesSize(from);
        ArrayIdx endArrayIdx;

        static if (is(T == string)) {
            if (to == "$")
                endArrayIdx = txt.length;
            else
                assert(false, "String to argument for graphemeSlice must be $");
        } else {
            endArrayIdx = txt.firstGraphemesSize(to);
        }
        return txt[startArrayIdx..endArrayIdx];
    }
}

// this

@safe unittest
{
    // test null
    gapbuffer("", 0).assertThrown;
    gapbuffer("", 1).assertThrown;
}
@safe unittest
{
    assertNotThrown(gapbuffer("", 1000_000));
}
@safe unittest
{
    auto gb = gapbuffer("", 2);
    assert(gb.buffer != null);
    assert(gb.buffer.length == 2);
}
@safe unittest
{
    auto gb = gapbuffer("", 2);
    assert(gb.buffer.length == 2);
    assert(gb.content.to!string == "");
    assert(gb.content.length == 0);
    assert(gb.contentAfterGap.length == 0);
    assert(gb.reallocCount == 0);
}
@safe unittest
{
    dstring text = "Some initial text";
    dstring combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 2);
        assert(gb.content.to!dstring == txt);
        assert(gb.contentBeforeGap.length == 0);
        assert(gb.contentAfterGap.to!dstring == txt);
        assert(gb.reallocCount == 0);
    }
}

// CheckCombiningGraphemes
@safe unittest
{
    // Checks the "stickyness" of hasCombinedGraphemes
    dstring text = "Some initial text";
    dstring combtext = "r̈a⃑⊥ b⃑67890";

    auto gb = gapbuffer("", 2);
    gb.checkCombinedGraphemes(text);
    assert(!gb.hasCombiningGraphemes);

    gb.checkCombinedGraphemes(combtext);
    assert(gb.hasCombiningGraphemes);

    gb.checkCombinedGraphemes(text);
    assert(gb.hasCombiningGraphemes);

    // Eval all the text
    gb.checkCombinedGraphemes;
    assert(!gb.hasCombiningGraphemes);

    gb.clear;
    assert(!gb.hasCombiningGraphemes);

    gb.clear(text);
    assert(!gb.hasCombiningGraphemes);

    gb.clear;
    assert(!gb.hasCombiningGraphemes);

    gb.addText(text);
    assert(!gb.hasCombiningGraphemes);

    gb.checkCombinedGraphemes;
    assert(!gb.hasCombiningGraphemes);
}

/// countGraphemes
@safe unittest
{
    // 17 dchars, 17 graphemes
    auto str_a = "some ascii string"d;
    // 20 dchars, 17 graphemes
    auto str_c = "ññññ r̈a⃑⊥ b⃑ string"d;

    auto gba = gapbuffer(str_a);
    assert(!gba.hasCombiningGraphemes);
    gba.cursorPos = 9999.GrpmIdx;

    auto gbc = gapbuffer(str_c);
    assert(gbc.hasCombiningGraphemes);
    gbc.cursorPos = 9999.GrpmIdx;

    auto gbc2 = gapbuffer(str_c);
    gbc2.forceFastMode = true;
    assert(gbc.hasCombiningGraphemes);

    assert(gba.countGraphemes(gba.buffer[0..4]) == 4);
    assert(gbc.countGraphemes(gbc.buffer[0..4]) == 4);
    assert(gbc2.countGraphemes(gbc.buffer[0..4]) == 4);

    assert(gba.countGraphemes(gba.buffer[0..17]) == 17);
    assert(gbc.countGraphemes(gbc.buffer[0..20]) == 17);
    assert(gbc2.countGraphemes(gbc2.buffer[0..20]) == 20);
}

// Unicode-optimizing indexes
// contentBeforeGapGrpmLen;
// contentAfterGapGrpmLen;

@safe unittest
{
    dstring combtext = "r̈a⃑⊥ b⃑67890"; // 10 graphemes, 13 len
    auto combtextGrpmLen = combtext.byGrapheme.count;

    auto gb = gapbuffer(combtext, 10);
    assert(gb.hasCombiningGraphemes);
    assert(gb.cursorPos == 0);
    assert(gb.contentBeforeGapGrpmLen == 0);
    assert(gb.contentAfterGapGrpmLen == combtextGrpmLen);

    gb.cursorForward(1.GrpmCount);
    assert(gb.cursorPos == 1);
    assert(gb.cursorPos == gb.cursorPos);
    assert(gb.contentBeforeGapGrpmLen == 1);
    assert(gb.contentAfterGapGrpmLen == combtextGrpmLen - 1);


    gb.cursorForward(1000.GrpmCount);
    assert(gb.cursorPos == combtextGrpmLen);
    assert(gb.cursorPos == gb.contentGrpmLen);
    assert(gb.contentBeforeGapGrpmLen == combtextGrpmLen);
    assert(gb.contentAfterGapGrpmLen == 0);

    gb.cursorBackward(1.GrpmCount);
    assert(gb.cursorPos == combtextGrpmLen - 1);
    assert(gb.cursorPos == gb.contentGrpmLen - 1);
    assert(gb.contentBeforeGapGrpmLen == combtextGrpmLen - 1);
    assert(gb.contentAfterGapGrpmLen == 1);

    gb.cursorBackward(GrpmCount(1000));
    assert(gb.cursorPos == 0);
    assert(gb.contentBeforeGapGrpmLen == 0);
    assert(gb.contentAfterGapGrpmLen == combtextGrpmLen);

    gb.cursorPos = GrpmCount(0);
    assert(gb.cursorPos == 0);
    assert(gb.contentBeforeGapGrpmLen == 0);
    assert(gb.contentAfterGapGrpmLen == combtextGrpmLen);
}


// idxDiffUntilGrapheme

@safe unittest
{
    dstring text = "Some initial text"; // 17 len & graphemes
    dstring combtext = "r̈a⃑⊥ b⃑67890"; // 10 graphemes, 13 len

    auto gb  = gapbuffer(text, 10);
    auto gbc = gapbuffer(combtext, 10);

    alias front = Direction.Front;
    assert(gb.idxDiffUntilGrapheme(gb.gapEnd, 4.GrpmCount, front) == 4);
    assert(gb.idxDiffUntilGrapheme(gb.gapEnd, gb.contentGrpmLen, front) == text.length);

    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd, gbc.contentGrpmLen, front) == combtext.length);
    assert(gbc.idxDiffUntilGrapheme(gbc.buffer.length - 4, 4.GrpmCount, front) == 4);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd, 1.GrpmCount, front) == 2);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 2, 1.GrpmCount, front) == 2);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 4, 1.GrpmCount, front) == 1);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 5, 1.GrpmCount, front) == 1);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 6, 1.GrpmCount, front) == 2);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 8, 1.GrpmCount, front) == 1);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 9, 1.GrpmCount, front) == 1);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 10, 1.GrpmCount, front) == 1);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 11, 1.GrpmCount, front) == 1);
    assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 12, 1.GrpmCount, front) == 1);
}


// content / contentAfterGap / contentBeforeGap

@safe unittest
{
    // Check that the slice returned by contentBeforeGap/AfterGap points to the same
    // memory positions as the original with not copying involved
    dstring text = "Some initial text";
    dstring combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 5);
        gb.cursorForward(3.GrpmCount);
        auto before = gb.contentBeforeGap;
        assert(&before[0] == &gb.buffer[0]);
        assert(&before[$-1] == &gb.buffer[gb.gapStart-1]);

        auto after = gb.contentAfterGap;
        assert(&after[0] == &gb.buffer[gb.gapEnd]);
        assert(&after[$-1] == &gb.buffer[$-1]);
    }
}

@safe unittest
{
    string text = "initial text";

    auto gb = gapbuffer(text);
    gb.cursorForward(7.GrpmCount);
    assert(gb.content.to!string == text);
    assert(gb.contentBeforeGap == "initial");
    assert(gb.contentAfterGap == " text");
    gb.addText(" inserted stuff");
    assert(gb.reallocCount == 0);
    assert(gb.content.to!string == "initial inserted stuff text");
    assert(gb.contentBeforeGap == "initial inserted stuff");
    assert(gb.contentAfterGap == " text");
}

@safe unittest
{
    string text = "¡Hola mundo en España!";
    auto gb = gapbuffer(text);
    assert(gb.content.to!string == text);
    assert(to!dstring(gb.content).length == 22);
    assert(to!string(gb.content).length == 24);

    gb.cursorForward(1.GrpmCount);
    assert(gb.contentBeforeGap == "¡");

    gb.cursorForward(4.GrpmCount);
    assert(gb.contentBeforeGap == "¡Hola");
    assert(gb.content.to!string == text);
    assert(gb.contentAfterGap == " mundo en España!");

    gb.addText(" más cosas");
    assert(gb.reallocCount == 0);
    assert(gb.content.to!string == "¡Hola más cosas mundo en España!");
    assert(gb.contentBeforeGap == "¡Hola más cosas");
    assert(gb.contentAfterGap == " mundo en España!");
}

// currentGapSize / configuredGapSize

@safe unittest
{
    dstring text = "Some initial text";
    dstring combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer("", 50);
        assert(gb.configuredGapSize == 50);
        assert(gb.currentGapSize == gb.configuredGapSize);
        gb.addText(txt);

        // New text if written on the gap so its size should be reduced
        assert(gb.currentGapSize == gb.configuredGapSize - asArray(txt).length);
        assert(gb.reallocCount == 0);
    }
}
@safe unittest
{
    dstring text =     "1234567890abcde";
    dstring combtext = "r̈a⃑⊥ b⃑67890abcde";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 50);
        // Deleting should recover space from the gap
        auto prevCurSize = gb.currentGapSize;
        gb.deleteRight(10.GrpmCount);
        assert(gb._newLinesDirty);

        assert(gb.currentGapSize == prevCurSize + txt.firstGraphemesSize(10.GrpmCount));
        assert(gb.content.to!dstring == "abcde");
        assert(gb.reallocCount == 0);
    }
}
@safe unittest
{
    dstring text     = "12345";
    dstring combtext = "r̈a⃑⊥ b⃑";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt);
        gb.deleteRight(5.GrpmCount);
        assert(gb._newLinesDirty);
        assert(gb.contentGrpmLen == 0);
    }
}
@safe unittest
{
    // Same to the left, if we move the cursor to the left of the text to delete
    dstring text     = "1234567890abc";
    dstring combtext = "r̈a⃑⊥ b⃑67890abc";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 50);
        auto prevCurSize = gb.currentGapSize;
        gb.cursorForward(10.GrpmCount);
        gb.deleteLeft(10.GrpmCount);
        assert(gb._newLinesDirty);
        assert(gb.currentGapSize == prevCurSize + txt.firstGraphemesSize(10.GrpmCount));
        assert(gb.content.to!string == "abc");
        assert(gb.reallocCount == 0);
    }
}
@safe unittest
{
    // Reassign to configuredGapSize. Should reallocate.
    dstring text     = "1234567890abc";
    dstring combtext = "r̈a⃑⊥ b⃑67890abc";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 50);
        gb.cursorForward(5.GrpmCount);
        assert(gb.contentBeforeGap == txt.graphemeSlice(0.GrpmIdx, 5.GrpmIdx));
        assert(gb.contentAfterGap == "67890abc");
        auto prevBufferLen = gb.buffer.length;

        gb.configuredGapSize = 100;
        assert(gb.reallocCount == 1);
        assert(gb.buffer.length == prevBufferLen + 50);
        assert(gb.currentGapSize == 100);
        assert(gb.content.to!dstring == txt);
        assert(gb.contentBeforeGap == txt.graphemeSlice(0.GrpmIdx, 5.GrpmIdx));
        assert(gb.contentAfterGap == "67890abc");
    }
}

// cursorForward / cursorBackward

@safe unittest
{
    dstring text     = "1234567890";
    dstring combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt);

        assert(gb.cursorPos == 0);

        gb.cursorForward(5.GrpmCount);
        assert(gb.cursorPos == 5);
        assert(gb.contentBeforeGap == txt.graphemeSlice(0.GrpmIdx, 5.GrpmIdx));
        assert(gb.contentAfterGap == "67890");

        gb.cursorForward(10_000.GrpmCount);
        gb.cursorBackward(4.GrpmCount);
        assert(gb.cursorPos == gb.length - 4);
        assert(gb.contentBeforeGap == txt.graphemeSlice(0.GrpmIdx, 6.GrpmIdx));
        assert(gb.contentAfterGap == "7890");

        immutable prevCurPos = gb.cursorPos;
        gb.cursorForward(0.GrpmCount);
        assert(gb.cursorPos == prevCurPos);
    }
}

// cursorPos

@safe unittest
{
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb  = gapbuffer(txt);
        assert(gb.contentGrpmLen == 10);
        assert(gb.cursorPos == 0);
        assert(gb.contentAfterGap.to!string == txt);

        gb.cursorPos = 6.GrpmIdx;
        assert(gb.contentGrpmLen == 10);
        assert(gb.cursorPos == 6);
        assert(gb.contentBeforeGap.to!string == txt.graphemeSlice(0.GrpmIdx, 6.GrpmIdx).text);
        assert(gb.contentAfterGap == "7890");

        gb.cursorPos(0.GrpmCount);
        assert(gb.cursorPos == 0);
        assert(gb.contentAfterGap.to!string == txt);
    }
}

// deleteLeft / deleteRight / addText

@safe unittest
{
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer("", 100);

        immutable prevGapStart = gb.gapStart;
        immutable prevGapEnd = gb.gapEnd;

        gb.addText(txt);
        assert(gb.content.to!string == txt);
        assert(gb.contentAfterGap == "");
        assert(gb.contentBeforeGap.to!string == txt);
        assert(gb.reallocCount == 0);
        assert(gb.gapStart == prevGapStart + asArray(txt).length);
        assert(gb.gapEnd == prevGapEnd);
        assert(gb._newLinesDirty);
    }
}
@safe unittest
{
    // Same test with a tiny gapsize to force reallocation
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer("", 10);
        immutable prevGapStart = gb.gapStart;
        immutable prevGapEnd = gb.gapEnd;

        // text is bigger than gap size so it should reallocate
        gb.addText(txt);
        assert(gb.reallocCount == 1);
        assert(gb.content.to!string == txt);
        assert(gb.gapStart == prevGapStart + asArray(txt).length);
        assert(gb.gapEnd == prevGapEnd + asArray(txt).length);
        assert(gb._newLinesDirty);
    }
}

@safe unittest
{
    auto gb = gapbuffer("", 10);

    immutable prevGapStart = gb.gapStart;
    immutable prevGapEnd = gb.gapEnd;
    immutable prevBufferSize = gb.buffer.length;

    assertNotThrown(gb.addText(""));

    assert(prevBufferSize == gb.buffer.length);
    assert(prevGapStart == gb.gapStart);
    assert(prevGapEnd == gb.gapEnd);
}

// deleteBetween
@safe unittest
{
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 10);
        auto oldMinusTwo = gb[2.GrpmIdx..$];
        gb.deleteBetween(0.GrpmIdx, 2.GrpmIdx);
        assert(gb.content == oldMinusTwo);
        assert(gb._newLinesDirty);

        gb = gapbuffer(txt, 10);
        auto oldMinutLastTwo = gb[0.GrpmIdx..8.GrpmIdx];
        gb.deleteBetween(8.GrpmIdx, 10.GrpmIdx);
        assert(gb.content == oldMinutLastTwo);

        gb = gapbuffer(txt, 10);
        gb.deleteBetween(0.GrpmIdx, 10.GrpmIdx);
        assert(gb.length == 0);

        gb = gapbuffer(txt, 10);
        auto oldMinusMiddle = gb[0.GrpmIdx..2.GrpmIdx] ~ gb[4.GrpmIdx..10.GrpmIdx];
        gb.deleteBetween(2.GrpmIdx, 4.GrpmIdx);
        assert(gb.content == oldMinusMiddle);
    }
}

// addAtPosition
@safe unittest
{
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 10);
        gb.addAtPosition(5.GrpmIdx, "foo");
        assert(gb[5.GrpmIdx..$.GrpmIdx] == "foo67890");
    }
}

// clear

/// clear without text
@safe unittest
{
    string text = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 10);
        auto oldBufLen = gb.buffer.length;
        gb.clear();

        // Should have not reallocated since the buffer is bigger than
        // text ("") + configuredGapSize
        assert(gb.buffer.length == oldBufLen);
        assert(gb.content.to!string == "");
        assert(gb.content.length == 0);
        assert(gb.gapStart == 0);
        assert(gb.gapEnd == gb.buffer.length);

        // should-reallocate test
        gb = gapbuffer(txt, 10);
        oldBufLen = gb.buffer.length;
        string newText = txt ~ txt ~ txt ~ txt;
        gb.clear(newText);

        assert(gb.buffer.length == (txt.to!dstring.length * 4) + gb.configuredGapSize);
        assert(gb.content.to!string == txt ~ txt ~ txt ~ txt);

    }
}

/// clear with some text, moving to the end
@safe unittest
{
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt, 10);
        auto newText = "some replacing stuff";
        gb.clear(newText, true);

        assert(gb.buffer.length == (gb.configuredGapSize + newText.length));
        assert(gb.content.length == newText.length);
        assert(gb.content.to!string == newText);
        assert(gb.cursorPos == newText.length);
        assert(gb.gapStart == newText.length);
        assert(gb.gapEnd == gb.buffer.length);
    }
}

/// clear with some text, moving to the start
@safe unittest
{
    auto gb = gapbuffer("Some initial text", 10);
    auto newText = "some replacing stuff";
    gb.clear(newText, false);

    assert(gb.buffer.length == (gb.configuredGapSize + newText.length));
    assert(gb.content.length == newText.length);
    assert(gb.content.to!string == newText);
    assert(gb.cursorPos == 0);
    assert(gb.gapStart == 0);
    // check that the text was written from the start and not using addtext
    assert(gb.gapEnd == gb.configuredGapSize);
}

// reallocate

@safe unittest
{
    // without adding new text
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt);
        gb.cursorForward(5.GrpmCount);
        immutable prevGapSize = gb.currentGapSize;
        immutable prevGapStart = gb.gapStart;
        immutable prevGapEnd = gb.gapEnd;
        immutable prevCursorPos = gb.cursorPos;

        gb.reallocate();
        assert(gb.reallocCount == 1);
        assert(gb.currentGapSize == prevGapSize);
        assert(prevGapStart == gb.gapStart);
        assert(prevGapEnd == gb.gapEnd);
        assert(prevCursorPos == gb.cursorPos);
    }
}
@safe unittest
{
    // adding new text
    string text     = "1234567890";
    string combtext = "r̈a⃑⊥ b⃑67890";

    foreach(txt; [text, combtext])
    {
        auto gb = gapbuffer(txt);
        gb.cursorForward(GrpmCount(4));

        immutable prevGapSize = gb.currentGapSize;
        immutable prevBufferLen = gb.buffer.length;
        immutable prevGapStart = gb.gapStart;
        immutable prevGapEnd = gb.gapEnd;
        immutable prevCursorPos = gb.cursorPos;

        string newtext = " and some new text ";
        gb.reallocate(newtext);
        assert(gb.reallocCount == 1);
        assert(gb.buffer.length == prevBufferLen + asArray(newtext).length);
        assert(gb.currentGapSize == prevGapSize);
        assert(gb.content.to!string ==
               txt.graphemeSlice(GrpmIdx(0), GrpmIdx(4)) ~
                    newtext ~
                    txt.graphemeSlice(GrpmIdx(4), "$"));
        assert(gb.gapStart == prevGapStart + asArray(newtext).length);
        assert(gb.gapEnd == prevGapEnd + asArray(newtext).length);
        assert(gb.cursorPos == prevCursorPos + newtext.byGrapheme.count);
    }
}

// opIndex

@safe unittest
{
    auto gb = gapbuffer("polompos");
    assert(gb[0] == "p");
    assert(gb[$-1] == "s");

    dstring combtext = "r̈a⃑⊥ b⃑67890";
    auto gbc = gapbuffer(combtext);
    assert(gbc[0] == "r̈");
    assert(gbc[1] == "a⃑");
    assert(gbc[2] == "⊥");
    assert(gbc[3] == " ");
    assert(gbc[4] == "b⃑");
    assert(gbc[5] == "6");
    assert(gbc[6] == "7");
    assert(gbc[7] == "8");
    assert(gbc[8] == "9");
    assert(gbc[9] == "0");
}

// opSlice

@safe unittest
{
    auto gb = gapbuffer("polompos");
    assert(gb[0..2] == "po");
    assert(gb[0..$.to!long] == "polompos");

    dstring combtext = "r̈a⃑⊥ b⃑67890";
    auto gbc = gapbuffer(combtext);
    assert(gbc[0..$.to!long] == combtext);
    assert(gbc[0..2] == "r̈a⃑");
    assert(gbc[3..5] == " b⃑");
    assert(gbc[5..$.to!long] == "67890");
}

@safe unittest
{
    auto gb = gapbuffer("polompos");
    assert(gb[] == "polompos");
    assert(gb.content == "polompos");

    dstring combtext = "r̈a⃑⊥ b⃑67890";
    auto gbc = gapbuffer(combtext);
    assert(gbc[] == combtext);
    assert(gbc[] == gbc.content);
}

// indexNewLines

@safe unittest
{
    auto gb = gapbuffer("012345678\n012\n", 10);
    gb.indexNewLines;
    assert(gb._newLines.length == 2);
    assert(gb._newLines[0] == 9);
    assert(gb._newLines[1] == 13);
    assert(gb._averageLineLenCP == 7);
    assert(!gb._newLinesDirty);
}
@safe unittest
{
    auto gb = gapbuffer("01234\n6789\n", 10);
    gb.cursorForward(5.GrpmCount);
    // \n just after gapEnd
    gb.indexNewLines;
    assert(gb._newLines.length == 2);
    assert(gb._newLines[0] == 5);
    assert(gb._newLines[1] == 10);
    assert(gb._averageLineLenCP == 6);

    gb.cursorForward(1.GrpmCount);
    // \n just before gapStart
    gb.indexNewLines;
    assert(gb._newLines.length == 2);
    assert(gb._newLines[0] == 5);
    assert(gb._newLines[1] == 10);
}
@safe unittest
{
    auto gb = gapbuffer("01234\n\n789\n", 10);
    // \n before and after gapStart
    gb.cursorForward(6.GrpmCount);
    gb.indexNewLines;
    assert(gb._newLines.length == 3);
    assert(gb._newLines[0] == 5);
    assert(gb._newLines[1] == 6);
    assert(gb._newLines[2] == 10);
}
@safe unittest
{
    auto gb = gapbuffer("\n", 10);
    gb.indexNewLines;
    assert(gb._newLines.length == 1);
    assert(gb._newLines[0] == 0);
    assert(gb._averageLineLenCP == 1);
}
@safe unittest
{
    auto gb = gapbuffer("\n\n", 10);
    gb.indexNewLines;
    assert(gb._newLines.length == 2);
    assert(gb._newLines[0] == 0);
    assert(gb._newLines[1] == 1);
    assert(gb._averageLineLenCP == 1);
}
@safe unittest
{
    auto gb = gapbuffer("12345", 10);
    gb.indexNewLines;
    assert(gb._newLines.length == 0);
    assert(gb._averageLineLenCP == 5);
}
@safe unittest
{
    auto gb = gapbuffer("", 10);
    gb.indexNewLines;
    assert(gb._newLines.length == 0);
    assert(gb._averageLineLenCP == 0);
}

// currentLine & lineAtPosition

@safe unittest
{
    string text =     "01\n34\n67\n90\n";
    string combtext = "01\n34\n67\n90\nr̈a⃑⊥ b⃑\n";

    foreach(txt; [text, combtext]) {
        auto gb = gapbuffer(txt, 10);
        gb.indexNewLines;

        assert(gb.currentLine == 0);   // pos = 0
        gb.cursorForward(1.GrpmCount); // pos = 1
        assert(gb.currentLine == 0);

        gb.cursorForward(1.GrpmCount); // pos = 2
        assert(gb.currentLine == 0);

        gb.cursorForward(1.GrpmCount); // pos = 3
        assert(gb.currentLine == 1);

        gb.cursorBackward(1.GrpmCount); // pos = 2
        assert(gb.currentLine == 0);

        gb.cursorForward(2.GrpmCount); // pos = 4
        assert(gb.currentLine == 1);

        gb.cursorForward(3.GrpmCount); // pos = 7
        assert(gb.currentLine == 2);

        gb.cursorForward(1.GrpmCount); // pos = 8
        assert(gb.currentLine == 2);

        gb.cursorForward(2.GrpmCount); // pos = 10
        assert(gb.currentLine == 3);

        gb.cursorForward(1.GrpmCount); // pos = 11
        assert(gb.currentLine == 3);
    }
}
