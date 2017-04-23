module neme.core.gapbuffer;

import std.algorithm.comparison : max, min;
import std.algorithm: copy, count;
import std.array : appender, insertInPlace, join, minimallyInitializedArray;
import std.container.array : Array;
import std.conv;
import std.exception: assertNotThrown, assertThrown, enforce;
import std.stdio;
import std.traits;
import std.uni: byGrapheme, byCodePoint;
import std.utf: byDchar;

debug {
    import std.array: replicate;
}

/**
 IMPORTANT terminology in this module:
 char = the internal array type, NOT grapheme or visual character
 grapheme = that

 Also, function parameters are size_t when they refer to base array positions
 and GrphIdx when the indexes are given in graphemes.

 Some functions have a "fast path" that operate by chars and a "slow path" that
 operate by graphemes. The path is selected by the hasCombiningChars member that
 is updated every time text is added to the buffer to the array is reallocated
 (currently no check is done when deleting characters for performance reasons).
*/

// The detection can be done with text.byCodePoint.count == test.byGrapheme.count

// TODO: typedefs for rawIdx (for the array) and charIdx (counting graphemes)

// TODO: add tests with combining chars

// TODO: migrate to iteration by grapheme

// TODO: check that I'm using const correctly

// TODO: implement other range interfaces

// TODO: unittest that normalize and asArray is working (with composed chars)

// TODO: add a demo mode (you type but the buffer representation is shown in
//       real time as you type or move the cursor)

// TODO: line number cache in the data structure

// TODO: benchmark against implementations in other languages

// TODO: explicit attributes, safe, nothrow, pure, etc

// TODO: add a "fastclear()": if buffer.length > newText, without reallocation. This will
// overwrite the start with the new text and then extend the gap from the end of
// the new text to the end of the buffer


/**
 * Struct user as Gap Buffer. It uses dchar (UTF32) characters internally for easier and
 * probably faster dealing with unicode chars since 1 dchar = 1 unicode char and slices are just direct indexes
 * without having to use libraries to get the indices of code points.
 * Params:
 * The template parameter StringT is only used for the text passed to the constructor since internally dchar
 * will be used
 */


struct GapBuffer(StringT=string)
    if(is(StringT == string) || is(StringT == wstring) || is(StringT == dstring))
{
public:
    /// Counter of reallocations done sync the struct was created to make room for
    /// text bigger than currentGapSize().
    ulong reallocCount;
    /// Counter the times the gap have been extended.
    ulong gapExtensionCount;

package:
    enum Direction { Front, Back }
    dchar[] buffer = null;
    ulong gapStart;
    ulong gapEnd;
    ulong _configuredGapSize;
    bool hasCombiningChars = false;

    // For array positions
    alias size_t = ulong;
    // For grapheme positions
    alias GrphIdx = ulong;

    // TODO: increase gap size to something bigger
    // FIXME: generic way to avoid two constructors for StringT and dchar?
    public this(dchar[] textarray, ulong gapSize = 100)
    {
        enforce(gapSize > 1, "Minimum gap size must be greater than 1");
        _configuredGapSize = gapSize;
        clear(textarray, false);
    }

    public this(StringT text, ulong gapSize = 100)
    {
        this(to!(dchar[])(text), gapSize);
    }

        @system unittest
        {
            /// test null
            GapBuffer("", 0).assertThrown;
            GapBuffer("", 1).assertThrown;
        }
        @system unittest
        {
            GapBuffer gb;
            assertNotThrown(gb = GapBuffer("", 1000_000));
        }
        ///
        @system unittest
        {
            auto gb = GapBuffer("", 2);
            assert(gb.buffer != null);
            assert(gb.buffer.length == 2);
        }
        @system unittest
       {
            auto gb = GapBuffer("", 2);
            assert(gb.buffer.length == 2);
            assert(gb.content.to!string == "");
            assert(gb.content.length == 0);
            assert(gb.contentAfterGap.length == 0);
            assert(gb.reallocCount == 0);
        }
        ///
        @system unittest
        {
            string text = "init with text";
            auto gb = GapBuffer(text.to!StringT, 2);
            assert(gb.content.to!string == text);
            assert(gb.contentBeforeGap.length == 0);
            assert(gb.contentAfterGap.to!string == text);
            assert(gb.reallocCount == 0);
        }

    pragma(inline)
    public void checkForMultibyteChars(T)(T text)
    {
        hasCombiningChars = text.byCodePoint.count != text.byGrapheme.count;
    }

    pragma(inline)
    private ulong countGraphemes(const dchar[] slice) const
    {
        // fast path
        if (!hasCombiningChars) {
            return slice.length;
        }
        // slow path
        return slice.byGrapheme.count;
    }

        unittest
        {
            // 17 dchars, 17 graphemes
            auto str_a = "some ascii string"d;
            // 20 dchars, 17 graphemes
            auto str_c = "ññññ r̈a⃑⊥ b⃑ string"d;

            auto test = "ññññ r̈a⃑⊥ b⃑ string"d;
            auto gba = GapBuffer!dstring(str_a);
            assert(!gba.hasCombiningChars);
            gba.cursorPos = 9999;

            auto gbc = GapBuffer!dstring(str_c);
            assert(gbc.hasCombiningChars);
            gbc.cursorPos = 9999;

            assert(gba.countGraphemes(gba.buffer[0..4]) == 4);
            assert(gbc.countGraphemes(gbc.buffer[0..4]) == 4);

            assert(gba.countGraphemes(gba.buffer[0..17]) == 17);
            assert(gbc.countGraphemes(gbc.buffer[0..20]) == 17);
        }


    // Return the number of dchars that numGraphemes graphemes occupy from
    // the given (array) position in the given direction. This doesnt checks
    // for the gap so the caller must have checked that
    package size_t idxDiffUntilGrapheme(size_t idx, ulong numGraphemes, Direction dir)
    {
        import std.range: take, tail;

        if (numGraphemes == 0)
            return 0;

        // fast path
        if (!hasCombiningChars) {
            return numGraphemes;
        }

        size_t charCount;
        if (dir == Direction.Front) {
            charCount = buffer[idx..$].byGrapheme.take(numGraphemes).byCodePoint.count;
        } else { // Direction.Back
            charCount = buffer[0..idx].byGrapheme.tail(numGraphemes).byCodePoint.count;
        }
        return charCount;
    }

        unittest
        {
            dstring text = "Some initial text";
            dstring combtext = "r̈a⃑⊥ b⃑67890";

            auto gb = GapBuffer!dstring(text);
            auto gbc = GapBuffer!dstring(combtext);

            alias front = gb.Direction.Front;
            assert(gb.idxDiffUntilGrapheme(gb.gapEnd, 4, front) == 4);
            assert(gb.idxDiffUntilGrapheme(gb.gapEnd, gb.graphemesCount, front) == text.length);

            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd, gbc.graphemesCount, front) == combtext.length);
            assert(gbc.idxDiffUntilGrapheme(gbc.buffer.length - 4, 4, front) == 4);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd,     1, front) == 2);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 2, 1, front) == 2);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 4, 1, front) == 1);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 5, 1, front) == 1);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 6, 1, front) == 2);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 8, 1, front) == 1);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 9, 1, front) == 1);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 10, 1, front) == 1);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 11, 1, front) == 1);
            assert(gbc.idxDiffUntilGrapheme(gbc.gapEnd + 12, 1, front) == 1);
        }

    pragma(inline)
    private dchar[] asArray(StrT = string)(StrT str)
        if(is(StrT == string) || is(StrT == wstring) || is(StrT == dstring))
    {
        return to!(dchar[])(str);
    }

    pragma(inline)
    dchar[] createNewGap(ulong gapSize=0)
    {
        // if a new gapsize was specified use that, else use the configured default
        ulong newGapSize = gapSize? gapSize: configuredGapSize;
        debug
        {
            return replicate(['-'.to!dchar], newGapSize);
        }
        else
        {
            return new dchar[](newGapSize);
        }
    }


    /** Print the raw contents of the buffer and a guide line below with the
     *  position of the start and end positions of the gap
     */
    public void debugContent()
    {
        writeln("gapstart: ", gapStart, " gapend: ", gapEnd, " len: ", buffer.length,
                " currentGapSize: ", currentGapSize, " configuredGapSize: ", configuredGapSize,
                " graphemesCount: ", graphemesCount);
        writeln("BeforeGap:|", contentBeforeGap,"|");
        writeln("AfterGap:|", contentAfterGap, "|");
        writeln("Text content:|", content, "|");
        writeln("Full buffer:");
        writeln(buffer);
        foreach (_; buffer[0 .. gapStart].byGrapheme)
        {
            write(" ");
        }
        write("^");
        foreach (_; buffer[gapStart .. gapEnd - 2].byGrapheme)
        {
            write("#");
        }
        write("^");
        writeln;
    }

    /**
     * Retrieve all the contents of the buffer. Unlike contentBeforeGap
     * and contentAfterGap the returned array will be newly instantiated, so
     * this method will be slower than the other two.
     *
     * Returns: The content of the buffer, as dchar.
     */
    pragma(inline)
    @property public const(dchar[]) content() const
    {
        return contentBeforeGap ~ contentAfterGap;
    }

    /**
     * Retrieve the textual content of the buffer until the gap/cursor.
     * The returned const array will be a direct reference to the
     * contents inside the buffer.
     */
    pragma(inline)
    @property public const(dchar[]) contentBeforeGap() const
    {
        return buffer[0..gapStart];
    }

    /**
     * Retrieve the textual content of the buffer after the gap/cursor.
     * The returned const array will be a direct reference to the
     * contents inside the buffer.
     */
    pragma(inline)
    @property public const(dchar[]) contentAfterGap() const
    {
        return buffer[gapEnd .. $];
    }

        ///
        @system unittest
        {
            // Check that the slice returned by contentBeforeGap/AfterGap points to the same
            // memory positions as the original with not copying involved
            auto gb = GapBuffer("polompos", 5);
            gb.cursorForward(3);
            auto before = gb.contentBeforeGap;
            assert(&before[0] == &gb.buffer[0]);
            assert(&before[$-1] == &gb.buffer[gb.gapStart-1]);

            auto after = gb.contentAfterGap;
            assert(&after[0] == &gb.buffer[gb.gapEnd]);
            assert(&after[$-1] == &gb.buffer[$-1]);
        }

        ///
        @system unittest
        {
            string text = "initial text";
            auto gb = GapBuffer(text.to!StringT);
            gb.cursorForward(7);
            assert(gb.content.to!string == text);
            assert(gb.contentBeforeGap == "initial");
            assert(gb.contentAfterGap == " text");
            gb.addText(" inserted stuff");
            assert(gb.reallocCount == 0);
            assert(gb.content.to!string == "initial inserted stuff text");
            assert(gb.contentBeforeGap == "initial inserted stuff");
            assert(gb.contentAfterGap == " text");
        }

        @system unittest
        {
            string text = "¡Hola mundo en España!";
            auto gb = GapBuffer(text.to!StringT);
            assert(gb.content.to!string == text);
            assert(to!dstring(gb.content).length == 22);
            assert(to!string(gb.content).length == 24);

            gb.cursorForward(1);
            assert(gb.contentBeforeGap == "¡");

            gb.cursorForward(4);
            assert(gb.contentBeforeGap == "¡Hola");
            assert(gb.content.to!string == text);
            assert(gb.contentAfterGap == " mundo en España!");

            gb.addText(" más cosas");
            assert(gb.reallocCount == 0);
            assert(gb.content.to!string == "¡Hola más cosas mundo en España!");
            assert(gb.contentBeforeGap == "¡Hola más cosas");
            assert(gb.contentAfterGap == " mundo en España!");
        }


    // Current gap size. The returned size is the number of chartype elements
    // (NOT bytes).
    pragma(inline)
    @property private ulong currentGapSize() const
    {
        return gapEnd - gapStart;
    }

    /**
     * This property will hold the value of the currently configured gap size.
     * Please note that this is the initial value at creation of reallocation
     * time but it can grow or shrink during the operation of the buffer.
     * Returns:
     *     The configured gap size.
     */
    pragma(inline)
    @property public ulong configuredGapSize() const
    {
        return _configuredGapSize;
    }

    /**
     * Asigning to this property will change the gap size that will be used
     * at creation and reallocation time and will cause a reallocation to
     * generate a buffer with the new gap.
     */
    pragma(inline)
    @property  public void configuredGapSize(ulong newSize)
    {
        enforce(newSize > 1, "Minimum gap size must be greater than 1");
        _configuredGapSize = newSize;
        reallocate();
    }
        @system unittest
        {
            auto gb = GapBuffer("", 50);
            assert(gb.configuredGapSize == 50);
            assert(gb.currentGapSize == gb.configuredGapSize);
            string newtext = "Some text to delete";
            gb.addText(newtext);

            // New text if written on the gap so its size should be reduced
            assert(gb.currentGapSize == gb.configuredGapSize - newtext.length);
            assert(gb.reallocCount == 0);
        }
        @system unittest
        {
            auto gb = GapBuffer("Some text to delete", 50);
            // Deleting should recover space from the gap
            auto prevCurSize = gb.currentGapSize;
            gb.deleteRight(10);
            assert(gb.currentGapSize == prevCurSize + 10);
            assert(gb.content.to!string == "to delete");
            assert(gb.reallocCount == 0);
        }
        @system unittest
        {
            auto gb = GapBuffer!string("123");
            gb.deleteRight(3);
            assert(gb.graphemesCount == 0);
        }
        @system unittest
        {
            // Same to the left, if we move the cursor to the left of the text to delete
            auto gb = GapBuffer("Some text to delete", 50);
            auto prevCurSize = gb.currentGapSize;
            gb.cursorForward(10);
            gb.deleteLeft(10);
            assert(gb.currentGapSize == prevCurSize + 10);
            assert(gb.content.to!string == "to delete");
            assert(gb.reallocCount == 0);
        }
        ///
        @system unittest
        {
            // Reassign to configuredGapSize. Should reallocate.
            auto gb = GapBuffer("Some text", 50);
            gb.cursorForward(5);
            assert(gb.contentBeforeGap == "Some ");
            assert(gb.contentAfterGap == "text");
            auto prevBufferLen = gb.buffer.length;

            gb.configuredGapSize = 100;
            assert(gb.reallocCount == 1);
            assert(gb.buffer.length == prevBufferLen + 50);
            assert(gb.currentGapSize == 100);
            assert(gb.content.to!string == "Some text");
            assert(gb.contentBeforeGap == "Some ");
            assert(gb.contentAfterGap == "text");
        }

    /// Returns the full size of the internal buffer including the gap in bytes
    /// For example for a GapBuffer!(string, dchar) with the content
    /// "1234" contentSize would return 16 (4 dchars * 4 bytes each) but
    /// contentSize would return 4 (dchars)
    pragma(inline)
    @property public ulong bufferByteSize() const
    {
        return buffer.sizeof;
    }

    /// Returns the size, in bytes, of the textual part of the buffer without the gap
    /// For example for a GapBuffer!(string, dchar) with the content
    /// "1234" contentSize would return 16 (4 dchars * 4 bytes each) but
    /// contentSize would return 4 (dchars)
    pragma(inline)
    @property private ulong contentByteSize() const
    {
        return (contentBeforeGap.length + contentAfterGap.length).sizeof;
    }

    /// Return the number of visual chars (graphemes). This number can be
    //different / from the number of chartype elements or even unicode code
    //points.
    pragma(inline)
    @property public ulong graphemesCount() const
    {
        if(hasCombiningChars) {
            return contentBeforeGap.byGrapheme.count +
                   contentAfterGap.byGrapheme.count;
        }
        return contentBeforeGap.length + contentAfterGap.length;
    }
    public alias length = graphemesCount;

    /**
     * Returns the cursor position (the gapStart)
     */
    pragma(inline)
    @property public ulong cursorPos() const
    {
        // fast path
        if (!hasCombiningChars)
            return gapStart;

        // FIXME: since this part is slow, we should now keep the cursor
        // position updated on insertions, deletions and cursor movements to
        // avoid this expensive shit of counting graphemes (when swithing
        // to pure unicode mode the cursor position should be saved at the
        // start)
        return countGraphemes(contentBeforeGap);
    }

    public void cursorForward(ulong graphemeCount)
    {

        if (graphemeCount <= 0 || buffer.length == 0 || gapEnd + 1 == buffer.length)
            return;

        auto graphemesToCopy = min(graphemeCount, countGraphemes(contentAfterGap));
        auto idxDiff = idxDiffUntilGrapheme(gapEnd, graphemesToCopy, Direction.Front);
        auto newGapStart = gapStart + idxDiff;
        auto newGapEnd = gapEnd + idxDiff;

        buffer[gapEnd..newGapEnd].copy(buffer[gapStart..newGapStart]);
        gapStart = newGapStart;
        gapEnd = newGapEnd;
    }

    /**
     * Moves the cursor backwards, copying the text left to the right to the
     * right side of the buffer.
     * Params:
     *     count = the number of places to move to the left.
     */
    public void cursorBackward(ulong graphemeCount)
    {
        if (graphemeCount <= 0 || buffer.length == 0 || gapStart == 0)
            return;

        auto graphemesToCopy = min(graphemeCount, countGraphemes(contentBeforeGap));
        auto idxDiff = idxDiffUntilGrapheme(gapStart, graphemesToCopy, Direction.Back);
        auto newGapStart = gapStart - idxDiff;
        auto newGapEnd = gapEnd - idxDiff;

        buffer[newGapStart..gapStart].copy(buffer[newGapEnd..gapEnd]);
        gapStart = newGapStart;
        gapEnd = newGapEnd;
    }

        ///
        @system unittest
        {
            string text = "Some initial text";
            string combtext = "r̈a⃑⊥ b⃑67890";
            auto gb = GapBuffer!string(text);
            auto gbc = GapBuffer!string(combtext);

            assert(gb.cursorPos == 0);
            assert(gbc.cursorPos == 0);

            gb.cursorForward(5);
            gbc.cursorForward(5);

            assert(gb.cursorPos == 5);
            assert(gbc.cursorPos == 5);

            assert(gb.contentBeforeGap == "Some ");
            assert(gbc.contentBeforeGap == "r̈a⃑⊥ b⃑");

            assert(gb.contentAfterGap == "initial text");
            assert(gbc.contentAfterGap == "67890");

            gb.cursorForward(10_000);
            gbc.cursorForward(10_000);

            gb.cursorBackward(4);
            gbc.cursorBackward(4);

            assert(gb.cursorPos == gb.content.length - 4);
            assert(gbc.cursorPos == gbc.content.byGrapheme.count - 4);

            assert(gb.contentBeforeGap == "Some initial ");
            assert(gbc.contentBeforeGap == "r̈a⃑⊥ b⃑6");

            assert(gb.contentAfterGap == "text");
            assert(gbc.contentAfterGap == "7890");

            immutable prevCurPos = gb.cursorPos;
            immutable cprevCurPos = gbc.cursorPos;
            gb.cursorForward(0);
            gbc.cursorForward(0);

            assert(gb.cursorPos == prevCurPos);
            assert(gbc.cursorPos == cprevCurPos);
        }
    /**
     * Sets the cursor position. The position is relative to
     * the text and ignores the gap
     */
    pragma(inline)
    @property public void cursorPos(ulong pos)
    {
        if (cursorPos > pos) {
            cursorBackward(cursorPos - pos);
        } else {
            cursorForward(pos - cursorPos);
        }
    }

        ///
        @system unittest
        {
            string text = "1234567890";
            string combtext = "r̈a⃑⊥ b⃑67890";
            auto gb  = GapBuffer(text.to!StringT);
            auto gbc = GapBuffer(combtext.to!StringT);
            assert(gb.graphemesCount == 10);
            assert(gbc.graphemesCount == 10);

            assert(gb.cursorPos == 0);
            assert(gbc.cursorPos == 0);

            assert(gb.contentAfterGap.to!string == text);
            assert(gbc.contentAfterGap.to!string == combtext);

            gb.cursorPos = 5;
            gbc.cursorPos = 5;
            assert(gb.graphemesCount == 10);
            assert(gbc.graphemesCount == 10);

            assert(gb.cursorPos == 5);
            assert(gbc.cursorPos == 5);

            assert(gb.contentBeforeGap == "12345");
            assert(gbc.contentBeforeGap == "r̈a⃑⊥ b⃑");

            assert(gb.contentAfterGap == "67890");
            assert(gbc.contentAfterGap == "67890");

            gb.cursorPos(0);
            gbc.cursorPos(0);

            assert(gb.cursorPos == 0);
            assert(gbc.cursorPos == 0);

            assert(gb.contentAfterGap.to!string == text);
            assert(gbc.contentAfterGap.to!string == combtext);
        }


    // XXX convert
    // Note: this wont call checkForMultibyteChars because it would have to check
    // the full text and it could be slow, so for example on a text with the slow
    // path enabled because it has combining chars deleting all the combining
    // chars with this method wont switch to the fast path like adding text do.
    // If you need that, call checkForMultibyteChars manually or wait for reallocation.
    /**
     * Delete count chars to the left of the cursor position, moving the gap (and the cursor) back
     * (typically the effect of the backspace key).
     *
     * Params:
     *     count = the numbers of chars to delete.
     */
    public void deleteLeft(ulong graphemeCount)
    {
        if (buffer.length == 0 || gapStart == 0)
            return;

        auto graphemesToDel = min(graphemeCount, countGraphemes(contentBeforeGap));
        auto idxDiff = idxDiffUntilGrapheme(gapStart, graphemesToDel, Direction.Back);
        gapStart = max(gapStart - idxDiff, 0);
    }

    // Note: this wont call checkForMultibyteChars because it would have to check
    // the full text and it could be slow, so for example on a text with the slow
    // path enabled because it has combining chars deleting all the combining
    // chars with this method wont switch to the fast path like adding text do.
    // If you need that, call checkForMultibyteChars manually or wait for reallocation.
    /**
      * Delete count chars to the right of the cursor position, moving the end of the gap to the right,
      * keeping the cursor at the same position
      *  (typically the effect of the del key).
      *
      * Params:
      *     count = the number of chars to delete.
      */
    public void deleteRight(ulong graphemeCount)
    {
        if (buffer.length == 0 || gapEnd == buffer.length)
            return;

        auto graphemesToDel = min(graphemeCount, countGraphemes(contentAfterGap));
        auto idxDiff = idxDiffUntilGrapheme(gapEnd, graphemesToDel, Direction.Front);
        gapEnd = min(gapEnd + idxDiff, buffer.length);
    }

    /**
     * Adds text, moving the cursor to the end of the new text. Could cause
     * a reallocation of the buffer.
     * Params:
     *     text = text to add.
     */
    public void addText(dchar[] text)
    {
        if (text.length >= currentGapSize) {
            // doesnt fill in the gap, reallocate the buffer adding the text
            reallocate(text);
        } else {
            checkForMultibyteChars(text);
            auto newGapStart = gapStart + text.length;
            text.copy(buffer[gapStart..newGapStart]);
            gapStart = newGapStart;
        }
    }

    pragma(inline)
    public void addText(StrT=string)(StrT text)
        if(is(StrT == string) || is(StrT == wstring) || is(StrT == dstring))
    {
        addText(asArray(text));
    }
        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer("", 100);
            string text = "some added text";
            immutable prevGapStart = gb.gapStart;
            immutable prevGapEnd = gb.gapEnd;

            gb.addText(text);
            assert(gb.content.to!string == "some added text");
            assert(gb.contentAfterGap == "");
            assert(gb.contentBeforeGap == "some added text");
            assert(gb.reallocCount == 0);
            assert(gb.gapStart == prevGapStart + text.length);
            assert(gb.gapEnd == prevGapEnd);
        }
        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer("", 10);
            immutable prevGapStart = gb.gapStart;
            immutable prevGapEnd = gb.gapEnd;

            // text is bigger than gap size so it should reallocate
            string text = "some added text";
            gb.addText(text);
            assert(gb.reallocCount == 1);
            assert(gb.content.to!string == text);
            assert(gb.gapStart == prevGapStart + text.length);
            assert(gb.gapEnd == prevGapEnd + text.length);
        }
        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer("", 10);
            immutable prevGapStart = gb.gapStart;
            immutable prevGapEnd = gb.gapEnd;
            immutable prevBufferSize = gb.buffer.length;

            assertNotThrown(gb.addText(""));
            assert(prevBufferSize == gb.buffer.length);
            assert(prevGapStart == gb.gapStart);
            assert(prevGapEnd == gb.gapEnd);
        }


    /**
     * Removes all pre-existing text from the buffer. You can also pass a
     * string to add new text after the previous ones has cleared (for example,
     * for the typical pasting with all the text preselected). This is
     * more efficient than clearing and then calling addText with the new
     * text
     */
    public void clear(dchar[] text=null, bool moveToEndEnd=true)
    {
        if (moveToEndEnd) {
            buffer = text ~ createNewGap();
            gapStart = text.length;
            gapEnd = buffer.length;
        } else {
            buffer = createNewGap() ~ text;
            gapStart = 0;
            gapEnd = _configuredGapSize;
        }
        checkForMultibyteChars(text);
    }

    pragma(inline)
    public void clear(StrT=string)(StrT text="", bool moveToEndEnd=true)
        if(is(StrT == string) || is(StrT == wstring) || is(StrT == dstring))
    {
        clear(asArray(text), moveToEndEnd);
    }

        // XXX add combined chars test
        /// clear without text
        @system unittest
        {
            auto gb = GapBuffer("Some initial text", 10);
            gb.clear();

            assert(gb.buffer.length == gb.configuredGapSize);
            assert(gb.content.to!string == "");
            assert(gb.content.length == 0);
            assert(gb.gapStart == 0);
            assert(gb.gapEnd == gb.configuredGapSize);
        }

        // XXX add combined chars test
        /// clear with some text, moving to the end
        @system unittest
        {
            auto gb = GapBuffer("Some initial text", 10);
            auto newText = "some replacing stuff";
            gb.clear(newText, true);

            assert(gb.buffer.length == (gb.configuredGapSize + newText.length));
            assert(gb.content.length == newText.length);
            assert(gb.content.to!string == newText);
            assert(gb.cursorPos == newText.length);
            assert(gb.gapStart == newText.length);
            assert(gb.gapEnd == gb.buffer.length);
        }

        // XXX add combined chars test
        /// clear with some text, moving to the start
        @system unittest
        {
            auto gb = GapBuffer("Some initial text", 10);
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

    // Reallocates the buffer, creating a new gap of the configured size.
    // If the textToAdd parameter is used it will be added just before the start of
    // the new gap. This is useful to do less copy operations since usually you
    // want to reallocate the buffer because you want to insert a new text that
    // if to big for the gap.
    // Params:
    //  textToAdd: when reallocating, add this text before/after the gap (or cursor)
    //      depending on the textDir parameter.
    private void reallocate(dchar[] textToAdd=null)
    {
        auto oldContentAfterGapLen = countGraphemes(contentAfterGap);

        // Check if the actual size of the gap is smaller than configuredSize
        // to extend the gap (and how much)
        dchar[] gapExtension;
        if (currentGapSize >= _configuredGapSize) {
            // no need to extend the gap
            gapExtension.length = 0;
        } else {
            gapExtension = createNewGap(configuredGapSize - currentGapSize);
            gapExtensionCount += 1;
        }

        buffer.insertInPlace(gapStart, textToAdd, gapExtension);
        gapStart += textToAdd.length;
        gapEnd = buffer.length - oldContentAfterGapLen;
        reallocCount += 1;

        checkForMultibyteChars(buffer);
    }

    pragma(inline)
    private void reallocate(StrT=string)(StrT textToAdd)
        if(is(StrT == string) || is(StrT == wstring) || is(StrT == dstring))
    {
        reallocate(asArray(textToAdd));
    }
        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer("Some text");
            gb.cursorForward(5);
            immutable prevGapSize = gb.currentGapSize;
            immutable prevGapStart = gb.gapStart;
            immutable prevGapEnd = gb.gapEnd;

            gb.reallocate();
            assert(gb.reallocCount == 1);
            assert(gb.currentGapSize == prevGapSize);
            assert(prevGapStart == gb.gapStart);
            assert(prevGapEnd == gb.gapEnd);
        }
        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer("Some text");
            gb.cursorForward(4);

            immutable prevGapSize = gb.currentGapSize;
            immutable prevBufferLen = gb.buffer.length;
            immutable prevGapStart = gb.gapStart;
            immutable prevGapEnd = gb.gapEnd;

            string newtext = " and some new text";
            gb.reallocate(" and some new text");
            assert(gb.reallocCount == 1);
            assert(gb.buffer.length == prevBufferLen + newtext.length);
            assert(gb.currentGapSize == prevGapSize);
            assert(gb.content.to!string == "Some and some new text text");
            assert(gb.gapStart == prevGapStart + newtext.length);
            assert(gb.gapEnd == prevGapEnd + newtext.length);
        }

    // Convert an index to the content to a real index in the buffer
    pragma(inline)
    private const(ulong) contentIdx2BufferIdx(ulong idx) const
    {
        if (idx >= gapStart) {
            return idx + currentGapSize;
        }
        // else: before the gap, direct translation
        return idx;
    }

        // XXX add combined chars test
        @system unittest
        {
            auto gapSize = 10;
            auto initialText = "Some initial content";
            auto gb = GapBuffer!string(initialText, gapSize);
            // new text is always at the end so all operations will need gapSize
            assert(gb.contentIdx2BufferIdx(0) == 0 + gapSize);
            assert(gb.contentIdx2BufferIdx(5) == 5 + gapSize);
            assert(gb.contentIdx2BufferIdx(initialText.length) == initialText.length + gapSize);

            // move the cursor back to the first word
            gb.cursorPos = 4;
            assert(gb.contentBeforeGap == "Some");
            assert(gb.contentIdx2BufferIdx(0) == 0);
            assert(gb.contentIdx2BufferIdx(3) == 3);
            assert(gb.contentIdx2BufferIdx(4) == 4 + gapSize);
        }

    //====================================================================
    //
    // Interface implementations and operators overloads
    //
    //====================================================================

    /**
     * $ (length) operator
     */
    public alias opDollar = graphemesCount;

    /**
     * index operator assignment: gapBuffer[2] = 'x';
     */
    pragma(inline)
    public dchar opIndexAssign(dchar value, ulong idx)
    {
        buffer[contentIdx2BufferIdx(idx)] = value;
        return value;
    }

        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer!string("012345");
            gb[0] = 'a';
            gb[5] = 'z';
            assert(gb.content[0] == 'a');
            assert(gb.content[5] == 'z');
        }

    /**
     * index operator read: auto x = gapBuffer[0..3]
     */
    // XXX convert
    pragma(inline)
    public const(dchar[]) opSlice(ulong start, ulong end) const
    {
        return content[start..end];
    }
        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer!string("polompos");
            assert(gb[0..2] == "po");
            assert(gb[0..$] == "polompos");
        }


    /**
     * index operator read: auto x = gapBuffer[]
     */
    pragma(inline)
    public const(dchar[]) opSlice() const
    {
        return content;
    }

        @system unittest
        {
            auto gb = GapBuffer!string("polompos");
            assert(gb[] == "polompos");
            assert(gb.content == "polompos");
        }

    /**
     * index operator assignment: gapBuffer[] = "some string" (replaces all);
     */
    pragma(inline)
    public ref GapBuffer opIndexAssign(dchar[] value)
    {
        clear(value);
        return this;
    }

    pragma(inline)
    public ref GapBuffer opIndexAssign(StrT=string)(StrT value)
        if(is(StrT == string) || is(StrT == wstring) || is(StrT == dstring))
    {
        return opIndexAssign(asArray(value));
    }

        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer!string("polompos");
            gb[] = "pokompos";
            assert(gb.content == "pokompos");
        }

    // input range interface methods
    pragma(inline)
    @property public bool empty() const
    {
        return !graphemesCount;
    }

        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer();
            assert(gb.empty);
            gb.addText("polompos");
            gb.cursorPos = 0;
            assert(!gb.empty);

            auto gb2 = GapBuffer!string("");
            assert(gb2.empty);

            auto gb3 = GapBuffer!string("polompos");
            assert(!gb3.empty);
            gb3.deleteRight(8);
            assert(gb3.empty);
        }

    /**
     * Implements the front range interface. For the GapBuffer
     * the front is the start of the content, NOT the content
     * from the cursor position.
     */
    // XXX convert
    @property public ref dchar front()
    {
        assert(graphemesCount > 0,
                "Attempt to fetch the front with the cursor at the end of the gapbuffer");
        if (gapStart == 0) {
            return buffer[gapEnd];
        }
        return buffer[0];
    }
        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer!string("Polompos");
            assert(gb.front == 'P');
            gb.deleteRight(1);
            assert(gb.front == 'o');
            gb.cursorForward(10);
            assert(gb.front == 'o');
            gb.deleteLeft(1);
            assert(gb.front == 'o');
        }

    /**
     * Implements the popFront range interface. This will delete the character to the first character
     * of the buffer (not the first after the cursor). This will move the cursor to the start.
     */
    @property public void popFront()
    {
        assert(graphemesCount > 0,
                "Attempt to popFront with the cursor at the end of the gapbuffer");
        cursorPos = 0;
        deleteRight(1);
    }

        // XXX add combined chars test
        @system unittest
        {
            auto gb = GapBuffer!string("Pok");
            auto clen = gb.graphemesCount;

            assert(gb.front == 'P');
            gb.popFront;
            clen--;
            assert(gb.front == 'o');
            assert(clen == gb.graphemesCount);

            gb.popFront;
            gb.cursorForward(1); // should have no effect
            clen--;
            assert(gb.front == 'k');
            assert(clen == gb.graphemesCount);

            gb.popFront;
            clen--;
            assert(clen == gb.graphemesCount);
            assert(clen == 0);
        }

        // XXX add combined chars test
        /// test the InputRange interface
        @system unittest
        {
            auto text = "Some initial text";
            auto gb = GapBuffer!string(text);

            auto idx = 0;
            for(auto r = gb; !r.empty; r.popFront) {
                assert(r.front == text[idx]);
                idx++;
            }
            // Should not change the original text
            assert(gb.content == "Some initial text");
        }

        // XXX add combined chars test
        /// test the foreach interface
        @system unittest
        {
            auto text = "Some initial text";
            GapBuffer!string gb = GapBuffer!string(text);

            ulong idx = 0;
            foreach(dchar d; gb) {
                assert(d == text[idx]);
                idx++;
            }
            assert(gb.content == "Some initial text");
        }

        // XXX add combined chars test
        @system unittest
        {
            import std.range.primitives: isInputRange;
            assert(isInputRange!(GapBuffer!string));
        }

        // XXX add combined chars test
        /// test library functions taking an InputRange or ForwardRange
        @system unittest
        {
            import std.range;
            import std.algorithm.comparison: equal;

            auto text = "Some initial text";
            auto gb = GapBuffer!string(text);

            auto text2 = " with more text"d;
            auto gb2 = GapBuffer!dstring(text2); // different type

            assert(gb.stride(2).equal("Sm nta et"));
            assert(chain(gb, gb2).equal(gb.content ~ gb2.content));
            assert(choose(false, gb, gb2).equal(gb2));
            assert(chooseAmong(0, gb, gb2).equal(gb));
            assert(roundRobin(gb, gb2).equal("S owmiet hi nmiotriea lt etxetxt"));
            assert(gb.takeOne.equal("S"));
            assert(gb.take(1000).equal(text));
            assert(gb.takeExactly(4).equal("Some"));
            assert(gb.tail(4).equal("text"));
            assert(gb.drop(5).equal("initial text"));
            assert(gb.dropOne.equal(text[1..$]));
            assert(gb.repeat(2)[0].equal(text));
            assert(gb.repeat(2)[1].equal(text));
            assert(gb.enumerate.length == 17);
            assert(zip(gb, gb2).length == 15);

            // TODO: refRange, padLeft, padRight
        }

    // Forward range interface
    // TODO: return a real copy, add specific unittest
    // XXX return this?
    @property public GapBuffer!StringT save()
    {
        auto gb = GapBuffer!StringT(this.content.dup);
        return gb;
    }

        // XXX add combined chars test
        @system unittest
        {
            import std.range.primitives: isForwardRange;
            assert(isForwardRange!(GapBuffer!string));
        }

        // XXX add combined chars test
        @system unittest
        {
            import std.range;
            import std.algorithm: equal, count;

            auto text = "Some initial text"; // textlength 17
            auto gb = GapBuffer!string(text);

            auto text2 = " with more text"d;
            auto gb2 = GapBuffer!dstring(text2); // different type

            assert(gb.cycle.take(text.length*2).equal(text ~ text));

            auto gb3 = GapBuffer!string("Another text");
            GapBuffer!string[] rangeOfGapBuffers = [gb, gb3];
            assert(rangeOfGapBuffers.transposed.count == 17);

            // FIXME: indexing by [] on chks doesnt work?
            auto chks = chunks(gb, 4);
            assert(chks.front.equal("Some"));
            chks.popFront;
            assert(chks.front.equal(" ini"));

            // TODO: evenchunks

        }
     //TODO: chunks, only, etc

}

// This must be outside of the template-struct. If tests inside the GapBuffer
// runs several times is because of this
// XXX add combined chars test
@system unittest
{
    string text = "init with text ñáñáñá";
    wstring wtext = "init with text ñáñáñá";
    dstring dtext = "init with text ñáñáñá";
    auto gb8 = GapBuffer!string(text);
    auto gb16 = GapBuffer!wstring(wtext);
    auto gb32 = GapBuffer!dstring(dtext);

    assert(gb8.graphemesCount == gb32.graphemesCount);
    assert(gb8.graphemesCount == gb16.graphemesCount);
    assert(gb8.content == gb32.content);
    assert(gb8.content == gb16.content);
    assert(gb8.content.to!string.length == 27);
    assert(gb8.content.to!wstring.length == 21);
    assert(gb8.content.to!dstring.length == gb32.content.to!dstring.length);
}
