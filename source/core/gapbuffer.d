module neme.core.gapbuffer;

import std.algorithm.comparison : max, min;
import std.algorithm: copy, count;
import std.array : appender, insertInPlace, join, minimallyInitializedArray;
import std.container.array : Array;
import std.conv;
import std.exception: assertNotThrown, assertThrown, enforce;
import std.range.primitives: popFrontExactly;
import std.range: take, drop, array, tail;
import std.stdio;
import std.traits;
import std.typecons: Typedef, Nullable, Flag, Yes, No;
import std.uni: byGrapheme, byCodePoint;
import std.utf: byDchar;
import core.memory: GC;

/**
 IMPORTANT terminology in this module:

 CUnit = the internal array type, NOT grapheme or visual character
 CPoint = Code point. Usually, but not always, same as a letter. On dchar
          1 CPoint = 1 CUnit but on UTF16 and UTF8 a CPoint can be more than 1
          CUnit.
 Letter = Grapheme, a visual character, using letter because is shorter and less
          alien-sounding for any normal person.

 Function parameters are ArrayIdx/Size when they refer to base array positions
 (code points) and GrpmIdx/Count when the indexes are given in graphemes.

 Some functions have a "fast path" that operate by chars and a "slow path" that
 operate by graphemes. The path is selected by the hasCombiningGraphemes member that
 is updated every time text is added to the buffer to the array is reallocated
 (currently no check is done when deleting characters for performance reasons).
*/

// TODO: add a demo mode (you type but the buffer representation is shown in
//       real time as you type or move the cursor)

// TODO: line number cache in the data structure

// TODO: add a "fastclear()": if buffer.length > newText, without reallocation. This will
// overwrite the start with the new text and then extend the gap from the end of
// the new text to the end of the buffer

// TODO: content() (probably) reallocates every time, think of a way to avoid that

// TODO: Unify doc comment style

/**
 * Struct user as Gap Buffer. It uses dchar (UTF32) characters internally for easier and
 * probably faster dealing with unicode chars since 1 dchar = 1 unicode char and slices are just direct indexes
 * without having to use libraries to get the indices of code points.
 */

// This seems to work pretty well for common use cases, can be changed
// with the property configuredGapSize
enum DefaultGapSize = 32 * 1024;
enum Direction { Front, Back }

alias BufferElement = dchar;
alias BufferType    = BufferElement[];

// For array positions / sizes. Using signed long to be able to detect negatives.
alias ArrayIdx   = long;
alias ImArrayIdx = immutable long;

alias ArraySize   = long;
alias ImArraySize = immutable long;

// For grapheme positions / sizes. These are Typedefs to avoid bugs
// related to mixing ArrayIdx's with GrpmIdx's
public alias GrpmIdx = Typedef!(long, long.init, "grapheme");
//public alias GrpmIdx = Typedef!(long, long.init, "grapheme");
public alias ImGrpmIdx = immutable GrpmIdx;

public alias GrpmCount = GrpmIdx;
public alias ImGrpmCount = immutable GrpmIdx;


@safe pure pragma(inline)
BufferType asArray(StrT = string)(StrT str)
    if(is(StrT == string) || is(StrT == wstring) || is(StrT == dstring)
       || is(BufferType) || is(wchar[]) || is(char[]))
{
    return to!(BufferType)(str.to!dstring);
}

@safe @nogc pure pragma(inline)
bool overlaps(ulong destStart, ulong destEnd, ulong sourceStart, ulong sourceEnd)
{
    return !(
        ((destStart < sourceStart && destEnd  < sourceEnd) &&
            (destStart < sourceEnd && destEnd < sourceStart)) ||
        ((destStart > sourceStart && destEnd  > sourceEnd) &&
            (destStart > sourceEnd && destEnd > sourceStart))
    );
}


public @safe pragma(inline)
GapBuffer gapbuffer(STR)(STR s, ArraySize gapSize = DefaultGapSize)
if (isSomeString!STR)
{
    return GapBuffer(asArray(s), gapSize);
}


public @trusted pragma(inline)
GapBuffer gapbuffer()
{
    return GapBuffer("", DefaultGapSize);
}

struct GapBuffer
{
    // The internal buffer holding the text and the gap
    package BufferType buffer = null;

    /// Counter of reallocations done since the struct was created to make room for
    /// text bigger than currentGapSize().
    package ulong reallocCount;

    /// Counter the times the gap have been extended.
    private ulong gapExtensionCount;

    // Gap location info vars
    package ArrayIdx gapStart;
    package ArrayIdx gapEnd;
    private ArraySize _configuredGapSize;

    // Catching some indexes and lengths to avoid having to iterate
    // by grapheme over unicode stuff when the "slow" multi-codepoint
    // mode is enabled
    package GrpmCount contentBeforeGapGrpmLen;
    package GrpmCount contentAfterGapGrpmLen;


    // If we have combining unicode chars (several code points for a single
    // grapheme) some methods switch to a slower unicode-striding implementation.
    // The detection and update of this boolean is done checkCombinedGraphemes().
    package bool _hasCombiningGraphemes = false;
    /// This will use the fast array-based version of all text operations even if the buffer
    /// contains multi code point graphemes. Enabling this will make multi cp graphemes
    /// to don't display correctly.
    public bool _forceFastMode = false;

    public @property @safe const pragma(inline)
    bool forceFastMode() const
    {
        return _forceFastMode;
    }
    public @property @safe pragma(inline)
    void forceFastMode(bool force)
    {
        _forceFastMode = force;

        if (!force)
            // Dont remove Yes.forceCheck, could cause a recursive loop
            checkCombinedGraphemes(content, Yes.forceCheck);
    }

    public @property @safe const pragma(inline)
    bool hasCombiningGraphemes()
    {
        if (forceFastMode)
            return false;
        return _hasCombiningGraphemes;
    }
    private @property @safe pragma(inline)
    void hasCombiningGraphemes(bool setComb)
    {
        _hasCombiningGraphemes = setComb;
    }

    /// Normal constructor for a BufferType
    public @safe
    this(const BufferType textarray, ArraySize gapSize = DefaultGapSize)
    {
        enforce(gapSize > 1, "Minimum gap size must be greater than 1");
        _configuredGapSize = gapSize;
        clear(textarray, false);
    }

    /// Overloaded constructor for string types
    public @safe
    this(Str=string)(Str text, ArraySize gapSize = DefaultGapSize)
    if (isSomeString!Str)
    {
        this(asArray(text), gapSize);
    }

    // If we have combining unicode chars (several code points for a single
    // grapheme) some methods switch to a slower unicode-striding implementation.
    // NOTE: this sets the global state of hasCombiningGraphemes so when checking
    // a block of text smaller than the total only call it if hasCombiningGraphemes
    // if false:
    // if (!hasCombiningGraphemes) checkCombinedGraphemes()
    package @safe pragma(inline)
    void checkCombinedGraphemes(const(BufferType) text, Flag!"forceCheck" forceCheck = No.forceCheck)
    {
        // TODO: short circuit the exit as soon as one difference is found
        // only a small text: only do the check if we didn't
        // had combined chars before (to avoid setting it to "false"
        // when it already had combined chars but the new text doesn't)
        if(forceCheck || !hasCombiningGraphemes) {
            hasCombiningGraphemes = text.byCodePoint.count != text.byGrapheme.count;
        }
    }
    package @safe pragma(inline)
    void checkCombinedGraphemes()
    {
        checkCombinedGraphemes(content, Yes.forceCheck);
    }


    // Returns the number of graphemes in the text.
    public @safe const pragma(inline) inout
    inout(GrpmCount) countGraphemes(const BufferType  slice)
    {
        // fast path
        if (forceFastMode || !hasCombiningGraphemes)
            return slice.length.GrpmCount;

        return slice.byGrapheme.count.GrpmCount;
    }

    // Starting from an ArrayIdx, count the number of codeunits that numGraphemes letters
    // take in the given direction.
    // TODO: check that this doesnt go over the gap
    package @trusted const pragma(inline)
    ArrayIdx idxDiffUntilGrapheme(ArrayIdx idx, GrpmCount numGraphemes, Direction dir)
    {
        // fast path
        if (forceFastMode || !hasCombiningGraphemes)
            return numGraphemes.to!ArrayIdx;

        if (numGraphemes == 0u)
            return ArrayIdx(0);

        ArrayIdx charCount;
        if (dir == Direction.Front) {
            charCount = buffer[idx..$].byGrapheme.take(numGraphemes.to!long).byCodePoint.count;
        } else { // Direction.Back
            charCount = buffer[0..idx].byGrapheme.tail(numGraphemes.to!long).byCodePoint.count;
        }
        return charCount;
    }

    // Create a new gap (empty array) with the configured size
    package @safe nothrow pragma(inline)
    BufferType createNewGap(ArraySize gapSize=0)
    {
        // if a new gapsize was specified use that, else use the configured default
        ImArraySize newGapSize = gapSize? gapSize: configuredGapSize;
        debug
        {
            import std.array: replicate;
            return replicate(['-'.to!BufferElement], newGapSize);
        }
        else
        {
            return new BufferType(newGapSize);
        }
    }


    /** Print the raw contents of the buffer and a guide line below with the
     *  position of the start and end positions of the gap
     */
    public @safe
    void debugContent()
    {
        writeln("gapstart: ", gapStart, " gapend: ", gapEnd, " len: ", buffer.length,
                " currentGapSize: ", currentGapSize, " configuredGapSize: ", configuredGapSize,
                " contentGrpmLen: ", contentGrpmLen);
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
     * Retrieve the textual content of the buffer until the gap/cursor.
     * The returned const array will be a direct reference to the
     * contents inside the buffer.
     */
    public @property @safe nothrow @nogc const pragma(inline)
    const(BufferType) contentBeforeGap()
    {
        return buffer[0..gapStart];
    }

    /**
     * Retrieve the textual content of the buffer after the gap/cursor.
     * The returned const array will be a direct reference to the
     * contents inside the buffer.
     */
    public @property @safe nothrow @nogc const pragma(inline)
    const(BufferType) contentAfterGap()
    {
        return buffer[gapEnd .. $];
    }

    /**
     * Retrieve all the contents of the buffer. Unlike contentBeforeGap
     * and contentAfterGap the returned array will be newly instantiated, so
     * this method will be slower than the other two.
     *
     * Returns: The content of the buffer, as BufferElement.
     */
    public @property @safe nothrow pragma(inline)
    const(BufferType) content()
    {
        return contentBeforeGap ~ contentAfterGap;
    }

    // Current gap size. The returned size is the number of chartype elements
    // (NOT bytes).
    public @property @safe nothrow @nogc const pragma(inline)
    ArraySize currentGapSize()
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
    public @property @safe nothrow pure @nogc const pragma(inline)
    ArraySize configuredGapSize()
    {
        return _configuredGapSize;
    }

    /**
     * Asigning to this property will change the gap size that will be used
     * at creation and reallocation time and will cause a reallocation to
     * generate a buffer with the new gap.
     */
    public @property @safe pragma(inline)
    void configuredGapSize(ArraySize newSize)
    {
        enforce(newSize > 1, "Minimum gap size must be greater than 1");
        _configuredGapSize = newSize;
        reallocate();
    }
    /// Return the number of visual chars (graphemes). This number can be
    /// different / from the number of chartype elements or even unicode code
    /// points.
    public @property @safe const pragma(inline)
    GrpmCount contentGrpmLen()
    {
        return GrpmCount(contentBeforeGapGrpmLen + contentAfterGapGrpmLen);
    }
    public alias length = contentGrpmLen;

    /**
     * Returns the cursor position
     */
    public @property @safe const pragma(inline)
    GrpmIdx cursorPos()
    out(res) { assert(res > 0); }
    body
    {
        return GrpmIdx(contentBeforeGapGrpmLen + 1);
    }

    /**
     * Sets the cursor position. The position is relative to
     * the text and ignores the gap
     */
    public @property @safe pragma(inline)
    void cursorPos(GrpmIdx pos)
    in { assert(pos > 0.GrpmIdx); }
    body
    {
        pos = min(pos, contentGrpmLen);

        if (pos < cursorPos) {
            cursorBackward(GrpmCount(cursorPos - pos));
        } else {
            cursorForward(GrpmCount(pos - cursorPos));
        }
    }

    /**
     * Moves the cursor forward, moving text to the left side of the gap.
     * Params:
     *     count = the number of places to move to the right.
     */
    public @safe
    ImGrpmIdx cursorForward(GrpmCount count)
    in { assert(count >= 0.GrpmCount); }
    out(res) { assert(res > 0); }
    body
    {
        if (count <= 0 || buffer.length == 0 || gapEnd + 1 == buffer.length)
            return cursorPos;

        ImGrpmCount actualToMoveGrpm = min(count, contentAfterGapGrpmLen);
        ImArrayIdx idxDiff = idxDiffUntilGrapheme(gapEnd, actualToMoveGrpm,
                Direction.Front);

        ImArrayIdx newGapStart = gapStart + idxDiff;
        ImArrayIdx newGapEnd = gapEnd + idxDiff;

        if (overlaps(gapStart, newGapStart, gapEnd, newGapEnd)) {
            buffer[gapStart..newGapStart] = buffer[gapEnd..newGapEnd].dup;
        } else {
            // slices dont overlap so no need to create a temporary
            buffer[gapStart..newGapStart] = buffer[gapEnd..newGapEnd];
        }

        gapStart = newGapStart;
        gapEnd   = newGapEnd;

        contentBeforeGapGrpmLen += actualToMoveGrpm.to!long;
        contentAfterGapGrpmLen  -= actualToMoveGrpm.to!long;
        //cursorPos               += actualToMoveGrpm.to!long;
        return cursorPos;
    }

    /**
     * Moves the cursor backwards, moving text to the right side of the gap.
     * Params:
     *     count = the number of places to move to the left.
     */
    public @trusted
    ImGrpmIdx cursorBackward(GrpmCount count)
    in { assert(count >= 0.GrpmCount); }
    out(res) { assert(res > 0); }
    body
    {
        if (count <= 0 || buffer.length == 0 || gapStart == 0)
            return cursorPos;

        ImGrpmCount actualToMoveGrpm = min(count, contentBeforeGapGrpmLen);
        ImArrayIdx idxDiff = idxDiffUntilGrapheme(gapStart, actualToMoveGrpm,
                Direction.Back);

        ImArrayIdx newGapStart = gapStart - idxDiff;
        ImArrayIdx newGapEnd = gapEnd - idxDiff;

        if (overlaps(newGapEnd, gapEnd, newGapStart, gapStart)) {
            buffer[newGapEnd..gapEnd] = buffer[newGapStart..gapStart].dup;
        } else {
            // slices dont overlap so no need to create a temporary
            buffer[newGapEnd..gapEnd] = buffer[newGapStart..gapStart];
        }


        gapStart = newGapStart;
        gapEnd  = newGapEnd;

        contentBeforeGapGrpmLen -= actualToMoveGrpm.to!long;
        contentAfterGapGrpmLen  += actualToMoveGrpm.to!long;

        return cursorPos;
    }

    // Note: this wont call checkCombinedGraphemes because it would have to check
    // the full text and it could be slow, so for example on a text with the slow
    // path enabled because it has combining chars deleting all the combining
    // chars with this method wont switch to the fast path like adding text do.
    // If you need that, call checkCombinedGraphemes manually or wait for reallocation.

    /**
     * Delete count chars to the left of the cursor position, moving the gap (and the cursor) back
     * (typically the effect of the backspace key).
     *
     * Params:
     *     count = the numbers of chars to delete.
     */
    public @trusted
    ImGrpmIdx deleteLeft(GrpmCount count)
    in { assert(count >= 0.GrpmCount); }
    out(res) { assert(res > 0); }
    body
    {
        if (buffer.length == 0 || gapStart == 0)
            return cursorPos;

        ImGrpmCount actualToDelGrpm = min(count, contentBeforeGapGrpmLen);
        ImArrayIdx idxDiff = idxDiffUntilGrapheme(gapStart, actualToDelGrpm,
                Direction.Back);

        gapStart = max(gapStart - idxDiff, 0);

        contentBeforeGapGrpmLen -= actualToDelGrpm.to!long;
        return cursorPos;
    }

    // Note: ditto.
    /**
      * Delete count chars to the right of the cursor position, moving the end of the gap to the right,
      * keeping the cursor at the same position
      *  (typically the effect of the del key).
      *
      * Params:
      *     count = the number of chars to delete.
      */
    public @trusted
    ImGrpmIdx deleteRight(GrpmCount count)
    in { assert(count >= 0.GrpmCount); }
    out(res) { assert(res > 0); }
    body
    {
        if (buffer.length == 0 || gapEnd == buffer.length)
            return cursorPos;

        ImGrpmCount actualToDelGrpm = min(count, contentAfterGapGrpmLen);
        ImArrayIdx idxDiff = idxDiffUntilGrapheme(gapEnd, actualToDelGrpm,
                Direction.Front);
        gapEnd = min(gapEnd + idxDiff, buffer.length);

        contentAfterGapGrpmLen -= actualToDelGrpm.to!long;

        return cursorPos;
    }

    /**
     * Adds text, moving the cursor to the end of the new text. Could cause
     * a reallocation of the buffer.
     * Params:
     *     text = text to add.
     */
    public @trusted
    ImGrpmIdx addText(const BufferType text)
    out(res) { assert(res > 0); }
    body
    {
        if (text.length >= currentGapSize) {
            // doesnt fill in the gap, reallocate the buffer adding the text
            reallocate(text);
        } else {
            checkCombinedGraphemes(text);
            ImArrayIdx newGapStart = gapStart + text.length;
            text.copy(buffer[gapStart..newGapStart]);
            gapStart = newGapStart;
        }

        // fast path
        GrpmIdx graphemesAdded;
        if (forceFastMode || !hasCombiningGraphemes) {
            graphemesAdded = text.length;
        } else {
            graphemesAdded = countGraphemes(text);
        }

        contentBeforeGapGrpmLen += graphemesAdded.to!long;
        return cursorPos;
    }

    public @safe pragma(inline)
    ImGrpmIdx addText(StrT=string)(StrT text)
        if (isSomeString!StrT)
    {
        return addText(asArray(text));
    }

    // Note: this is slow on the slow path so it should only be used on things
    // that are slow anyway like clear() or reallocate()
    package @trusted pragma(inline)
    void updateGrpmLens()
    {
        if (forceFastMode || !hasCombiningGraphemes) {
            // fast path
            contentBeforeGapGrpmLen = contentBeforeGap.length;
            contentAfterGapGrpmLen  = contentAfterGap.length;
        } else {
            // slow path
            contentBeforeGapGrpmLen = countGraphemes(contentBeforeGap);
            contentAfterGapGrpmLen  = countGraphemes(contentAfterGap);
        }
    }

    /**
     * Removes all pre-existing text from the buffer. You can also pass a
     * string to add new text after the previous ones has cleared (for example,
     * for the typical pasting with all the text preselected). This is
     * more efficient than clearing and then calling addText with the new
     * text
     */
    public @safe
    ImGrpmIdx clear(const BufferType text, bool moveToEndEnd=true)
    out(res) { assert(res > 0); }
    body
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

        checkCombinedGraphemes();
        updateGrpmLens();
        return cursorPos;
    }
    public @safe
    ImGrpmIdx clear()
    out(res) { assert(res > 0); }
    body
    {
        return clear(null, false);
    }
    public @safe pragma(inline)
    ImGrpmIdx clear(StrT=string)(StrT text="", bool moveToEndEnd=true)
    if (isSomeString!StrT)
    {
        return clear(asArray(text), moveToEndEnd);
    }

    // Reallocates the buffer, creating a new gap of the configured size.
    // If the textToAdd parameter is used it will be added just before the start of
    // the new gap. This is useful to do less copy operations since usually you
    // want to reallocate the buffer because you want to insert a new text that
    // if to big for the gap.
    // Params:
    //  textToAdd: when reallocating, add this text before/after the gap (or cursor)
    //      depending on the textDir parameter.
    package @trusted
    void reallocate(const BufferType textToAdd)
    {
        ImArraySize oldContentAfterGapSize = contentAfterGap.length;

        // Check if the actual size of the gap is smaller than configuredSize
        // to extend the gap (and how much)
        BufferType gapExtension;
        if (currentGapSize >= _configuredGapSize) {
            // no need to extend the gap
            gapExtension.length = 0;
        } else {
            gapExtension = createNewGap(configuredGapSize - currentGapSize);
            gapExtensionCount += 1;
        }

        buffer.insertInPlace(gapStart, textToAdd, gapExtension);
        gapStart += textToAdd.length;
        gapEnd = buffer.length - oldContentAfterGapSize;
        reallocCount += 1;

        checkCombinedGraphemes();
        updateGrpmLens();
    }
    package @trusted pragma(inline)
    void reallocate()
    {
        reallocate(null);
    }
    package @safe pragma(inline)
    void reallocate(StrT=string)(StrT textToAdd)
    if (isSomeString!StrT)
    {
        reallocate(asArray(textToAdd));
    }

    /+
     ╔══════════════════════════════════════════════════════════════════════════════
     ║ ⚑ Operator[] overloads
     ╚══════════════════════════════════════════════════════════════════════════════
    +/

    /**
     * $ (length) operator
     */
    public alias opDollar = contentGrpmLen;

    /// OpIndex: BufferType b = gapbuffer[3];
    /// Please note that this returns a BufferType and NOT a single
    /// BufferElement because the returned character could take several code points/units.
    public @safe pragma(inline)
    const(BufferType) opIndex(GrpmIdx pos)
    {
        // fast path
        if (forceFastMode || !hasCombiningGraphemes)
            return [content[pos.to!long]];

        return content.byGrapheme.drop(pos.to!long).take(1).byCodePoint.array.to!(BufferType);
    }
    public @safe pragma(inline)
    const(BufferType) opIndex(long pos)
    {
        return opIndex(pos.GrpmIdx);
    }

    /**
     * index operator read: auto x = gapBuffer[0..3]
     */
    public @trusted pragma(inline)
    const(BufferType) opSlice(GrpmIdx start, GrpmIdx end)
    {
        // fast path
        if (forceFastMode || !hasCombiningGraphemes) {
            return content[start.to!long..end.to!long];
        }

        // slow path
        return content.byGrapheme.drop(start.to!long)
                      .take(end.to!long - start.to!long)
                      .byCodePoint.array.to!(BufferType);
    }
    public @safe pragma(inline)
    const(BufferType) opSlice(long start, long end)
    {
        return opSlice(start.GrpmIdx, end.GrpmIdx);
    }

    /**
     * index operator read: auto x = gapBuffer[]
     */
    public @safe nothrow pragma(inline)
    const(BufferType) opSlice()
    {
        return content;
    }
}
