module neme.core.gapbuffer;

// TODO: move these to local imports when only used once
import core.memory: GC;
import std.algorithm.comparison : max, min;
import std.algorithm.searching: canFind;
import std.algorithm: copy, count;
import std.array : appender, insertInPlace, join, minimallyInitializedArray;
import std.container.array : Array;
import std.conv;
import std.exception: assertNotThrown, assertThrown, enforce;
import std.range.primitives: popFrontExactly;
import std.range: take, drop, array, tail;
import std.stdio;
import std.traits;
import std.typecons: Typedef, Flag, Yes, No;
import std.uni: byCodePoint, byGrapheme;
import std.utf: byDchar;

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
 is updated every time text is added to the buffer or the array is reallocated
 (currently no check is done when deleting characters for performance reasons).
*/

// TODO: scope all the things

// TODO: update the line number cache on modify, check if it has to be done also
// for move

// TODO: add a demo mode (you type but the buffer representation is shown in
//       real time as you type or move the cursor)

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

// TODO: unittest
package pure @safe @nogc pragma(inline)
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


public @safe pragma(inline)
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
    package bool hasCombiningGraphemes = false;
    /// This will use the fast array-based version of all text operations even if the buffer
    /// contains multi code point graphemes. Enabling this will make multi cp graphemes
    /// to don't display correctly.
    package bool _forceFastMode = false;

    // Map holding the (absolute and without accounting for the gap, ArrayIdx)
    // position of all newline characters. The key is the line
    // number and the value is an array with the newline offset
    package ArrayIdx[ArrayIdx] _newLines;

    // Marks if line number cache is dirty (text modifed without calling indexNewLines)
    package bool _newLinesDirty = true;

    // Average line length in the file, in code points, including the newline character.
    // Used to optimize currentLine. Updated on indexNewLines(buffer)
    package ArraySize _averageLineLenCP = 90;

    package const pure nothrow @safe @nogc pragma(inline)
    bool insideGap(ArrayIdx pos)
    {
        return (pos >= gapStart && pos < gapEnd);
    }

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
        // Only a small text: only do the check if we didn't
        // had combined chars before (to avoid setting it to "false"
        // when it already had combined chars but the new text doesn't)

        if (!forceFastMode && (forceCheck || !hasCombiningGraphemes)) {
            foreach(gpm; text.byGrapheme) {
                // Short circuit the loop as soon as a multi CP grapheme is found
                if (gpm.length > 1) {
                    hasCombiningGraphemes = true;
                    return;
                }
            }

            hasCombiningGraphemes = false;
        }
    }
    package @safe pragma(inline)
    void checkCombinedGraphemes()
    {
        checkCombinedGraphemes(content, Yes.forceCheck);
    }


    // Returns the number of graphemes in the text.
    public const @safe pragma(inline) inout
    inout(GrpmCount) countGraphemes(const BufferType  slice)
    {
        // fast path
        if (_forceFastMode || !hasCombiningGraphemes)
            return slice.length.GrpmCount;

        return slice.byGrapheme.count.GrpmCount;
    }

    // Starting from an ArrayIdx, count the number of codeunits that numGraphemes letters
    // take in the given direction.
    // TODO: check that this doesnt go over the gap
    package const @safe pragma(inline)
    ArrayIdx idxDiffUntilGrapheme(ArrayIdx idx, GrpmCount numGraphemes, Direction dir)
    {
        // fast path
        if (_forceFastMode || !hasCombiningGraphemes)
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
    package nothrow @safe pragma(inline)
    BufferType createNewGap(ArraySize gapSize=0)
    {
        // if a new gapsize was specified use that, else use the configured default
        ImArraySize newGapSize = gapSize? gapSize: _configuredGapSize;
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
        import std.array: replace;

        writeln("gapstart: ", gapStart, " gapend: ", gapEnd, " len: ", buffer.length,
                " currentGapSize: ", currentGapSize, " configuredGapSize: ", _configuredGapSize,
                " contentGrpmLen: ", contentGrpmLen, " contentCPLen: ", content.byCodePoint.count);
        writeln("BeforeGap:|", contentBeforeGap.replace("\n", "/"),"|");
        writeln("AfterGap:|", contentAfterGap.replace("\n", "/"), "|");
        writeln("Text content:|", content.replace("\n", "/"), "|");
        writeln("Full buffer:");
        writeln(buffer.replace("\n", "/"));
        foreach (_; buffer[0 .. gapStart].byGrapheme)
        {
            write(" ");
        }
        write("^");
        if (gapEnd - 2 > gapStart) {
            foreach (_; buffer[gapStart .. gapEnd - 2].byGrapheme)
            {
                write("#");
            }
            write("^");
        }
        writeln;
    }

    /**
     * Retrieve the textual content of the buffer until the gap/cursor.
     * The returned const array will be a direct reference to the
     * contents inside the buffer.
     */
    public const pure nothrow @property @safe @nogc pragma(inline)
    const(BufferType) contentBeforeGap()
    {
        return buffer[0..gapStart];
    }

    /**
     * Retrieve the textual content of the buffer after the gap/cursor.
     * The returned const array will be a direct reference to the
     * contents inside the buffer.
     */
    public const pure nothrow @property @safe @nogc pragma(inline)
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
    public const pure nothrow @property @safe pragma(inline)
    const(BufferType) content()
    {
        return contentBeforeGap ~ contentAfterGap;
    }

    // Current gap size. The returned size is the number of chartype elements
    // (NOT bytes).
    public const pure nothrow @property @safe @nogc pragma(inline)
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
    public const pure nothrow @property @safe @nogc pragma(inline)
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

        // If the newSize if bigger than the current gap, reallocate
        if (newSize > currentGapSize) {
            reallocate();
        }
    }

    /// Return the number of code points. This number can be
    /// different / from the number of graphemes (visual characters) elements
    /// if the text contain multi-cp graphemes.
    public const pure nothrow @property @safe pragma(inline)
    ArraySize contentCPLen()
    {
        return buffer.length - currentGapSize;
    }

    /// Return the number of visual chars (graphemes). This number can be
    /// different / from the number of chartype elements or even unicode code
    /// points.
    public const pure @property @safe pragma(inline)
    GrpmCount contentGrpmLen()
    {
        return GrpmCount(contentBeforeGapGrpmLen + contentAfterGapGrpmLen);
    }
    public alias length = contentGrpmLen;

    /**
     * Returns the cursor position
     */
    public const pure nothrow @property @safe pragma(inline)
    GrpmIdx cursorPos()
    out(res) { assert(res >= 0); }
    body
    {
        return GrpmIdx(contentBeforeGapGrpmLen);
    }

    /**
     * Sets the cursor position. The position is relative to
     * the text and ignores the gap
     */
    public @property @safe pragma(inline)
    void cursorPos(GrpmIdx pos)
    in { assert(pos >= 0.GrpmIdx); }
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
    out(res) { assert(res >= 0); }
    body
    {
        if (count <= 0 || buffer.length == 0 || gapEnd + 1 == buffer.length)
            return cursorPos;

        ImGrpmCount actualToMoveGrpm = min(count, contentAfterGapGrpmLen);
        ImArrayIdx idxDiff = idxDiffUntilGrapheme(gapEnd, actualToMoveGrpm,
                Direction.Front);

        ImArrayIdx newGapStart = gapStart + idxDiff;
        ImArrayIdx newGapEnd   = gapEnd   + idxDiff;

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
        return cursorPos;
    }

    /**
     * Moves the cursor backwards, moving text to the right side of the gap.
     * Params:
     *     count = the number of places to move to the left.
     */
    public @safe
    ImGrpmIdx cursorBackward(GrpmCount count)
    in { assert(count >= 0.GrpmCount); }
    out(res) { assert(res >= 0); }
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
    public @safe
    ImGrpmIdx deleteLeft(GrpmCount count)
    in { assert(count >= 0.GrpmCount); }
    out(res) { assert(res >= 0); }
    body
    {
        if (buffer.length == 0 || gapStart == 0)
            return cursorPos;

        ImGrpmCount actualToDelGrpm = min(count, contentBeforeGapGrpmLen);
        ImArrayIdx idxDiff = idxDiffUntilGrapheme(gapStart, actualToDelGrpm,
                Direction.Back);

        auto oldGapStart = gapStart;
        gapStart = max(gapStart - idxDiff, 0);
        contentBeforeGapGrpmLen -= actualToDelGrpm.to!long;
        _newLinesDirty = true;

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
    public @safe
    ImGrpmIdx deleteRight(GrpmCount count)
    in { assert(count >= 0.GrpmCount); }
    out(res) { assert(res >= 0); }
    body
    {
        if (buffer.length == 0 || gapEnd == buffer.length)
            return cursorPos;

        ImGrpmCount actualToDelGrpm = min(count, contentAfterGapGrpmLen);
        ImArrayIdx idxDiff = idxDiffUntilGrapheme(gapEnd, actualToDelGrpm,
                Direction.Front);

        auto oldGapEnd = gapEnd;
        gapEnd = min(gapEnd + idxDiff, buffer.length);
        contentAfterGapGrpmLen -= actualToDelGrpm.to!long;
        _newLinesDirty = true;

        return cursorPos;
    }

    /*
     * Delete the text between the specified grapheme positions.
     * Returns:
     *  The cursor position at the end.
     */
    public @safe
    ImGrpmIdx deleteBetween(GrpmIdx start, GrpmIdx end)
    in { assert(end > start); assert(start >= 0); }
    body
    {
        if (end > contentGrpmLen || start < 0)
            return cursorPos;

        cursorPos = start;
        deleteRight(GrpmCount(end - start));

        return cursorPos;
    }

    /**
     * Adds text, moving the cursor to the end of the new text. Could cause
     * a reallocation of the buffer.
     * Params:
     *     text = text to add.
     */
    public @safe
    ImGrpmIdx addText(const BufferType text)
    out(res) { assert(res >= 0); }
    body
    {
        if (text.length == 0)
            return cursorPos;

        bool reallocated = false;
        auto oldGapStart = gapStart;

        if (text.length >= currentGapSize) {
            // doesnt fill in the gap, reallocate the buffer adding the text
            reallocate(text);
            reallocated = true;
        } else {
            checkCombinedGraphemes(text);
            ImArrayIdx newGapStart = gapStart + text.length;
            text.copy(buffer[gapStart..newGapStart]);
            gapStart = newGapStart;
        }

        GrpmIdx graphemesAdded;
        // fast path
        if (_forceFastMode || !hasCombiningGraphemes) {
            graphemesAdded = text.length;
        } else {
            graphemesAdded = countGraphemes(text);
        }

        contentBeforeGapGrpmLen += graphemesAdded.to!long;
        _newLinesDirty = true;

        return cursorPos;
    }

    public @safe pragma(inline)
    ImGrpmIdx addText(StrT=string)(StrT text)
        if (isSomeString!StrT)
    {
        return addText(asArray(text));
    }

    /**
     * Adds text at the specific position. This will move the cursor.
     * Returns:
     *  The new cursor position
     */
    public @safe pragma(inline)
    ImGrpmIdx addAtPosition(ImGrpmIdx start, const BufferType text)
    {
        cursorPos = start;
        addText(text);
        return cursorPos;
    }

    // Note: this is slow on the slow path so it should only be used on things
    // that are slow anyway like clear() or reallocate()
    package @safe pragma(inline)
    void updateGrpmLens()
    {
        if (_forceFastMode || !hasCombiningGraphemes) {
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
    out(res) { assert(res >= 0); }
    body
    {
        bool noRealloc = buffer.length >= text.length + _configuredGapSize;

        if (moveToEndEnd) {
            if (noRealloc) {
                buffer[0..text.length] = text;
                gapStart = text.length;
                gapEnd = buffer.length;
            } else {
                buffer = text ~ createNewGap();
                gapStart = text.length;
                gapEnd = gapStart + _configuredGapSize;
            }
            gapEnd = buffer.length;
        } else {
            if (noRealloc) {
                gapStart = 0;
                gapEnd = buffer.length - text.length;
                buffer[gapEnd..$] = text;
            } else {
                buffer = createNewGap() ~ text;
                gapStart = 0;
                gapEnd = _configuredGapSize;
            }
        }

        checkCombinedGraphemes();
        updateGrpmLens();
        indexNewLines();

        return cursorPos;
    }
    public @safe
    ImGrpmIdx clear()
    out(res) { assert(res >= 0); }
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
            gapExtension = createNewGap(_configuredGapSize - currentGapSize);
            gapExtensionCount += 1;
        }

        buffer.insertInPlace(gapStart, textToAdd, gapExtension);
        gapStart += textToAdd.length;
        gapEnd = buffer.length - oldContentAfterGapSize;
        ++reallocCount;

        checkCombinedGraphemes();
        updateGrpmLens();
        indexNewLines();
    }
    package @safe pragma(inline)
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

    // Implementation note: in exploratory/ there is a parallel (and uglier) version of this but for
    // normal files it was 25x slower than this serial version. For 100MB files it was about
    // the same speed and from there it was faster; could be recovered if in the future I add a
    // "big file mode".

    // TODO: fuzzy test
    public @trusted @property
    void indexNewLines()
    {
        if (!_newLinesDirty)
            return;

        scope(success)
            _newLinesDirty = false;

        ArrayIdx nlIndex;
        // For calculating the average line length, to optimize currentLine():
        ArraySize linesLengthSum;
        ArrayIdx prevOffset;
        bool afterGap = false;

        foreach(ref offset, cp; buffer) {
            if (insideGap(offset)) {
                // ignore the gap
                offset = gapEnd - 1;
                continue;
            }

            if(!afterGap && offset >= gapEnd)
                afterGap = true;

            // offset without the gap (by-content):
            ArrayIdx noGapOffset = offset;

            if (cp == '\n') {
                if (afterGap) {
                    noGapOffset = offset - currentGapSize;
                }

                // Store in the map [newLine#] : newlineOffset
                _newLines[nlIndex] = noGapOffset;
                ++nlIndex;

                // Add the current line length (numchars from the prevOffset to this \n)
                linesLengthSum += noGapOffset - prevOffset + 1;
                prevOffset = noGapOffset;
            }
        }

        _averageLineLenCP = _newLines.length > 0 ? linesLengthSum / nlIndex : contentCPLen;
    }

    // TODO: iterator by line

    // TODO: fuzzy test this
    /**
     * Returns the current line inside the buffer (0-based index).
     */
    public @safe
    ArrayIdx lineAtPosition(ArrayIdx pos)
    {
        if (_newLinesDirty)
            indexNewLines();

        if (_newLines.length < 2 || _averageLineLenCP == 0)
            return 0;

        ArrayIdx aprox = min(_newLines.length - 1, pos / _averageLineLenCP);

        while (true) {
            if (aprox >_newLines.length || aprox < 0) {
                return aprox;
            }

            auto guessNewlinePos = _newLines[aprox];
            if (guessNewlinePos == pos) {
                // Lucky shot
                return aprox;
            }

            if (guessNewlinePos > pos) {
                // Current position if after the guessed newline

                if (aprox == 0)
                    // and it was the first, so found
                    return 0;

                // Check the position of the previous newline to see if our pos is between them
                if (_newLines[aprox - 1] < pos) {
                    return aprox;
                }
                // Not found, continue searching back
                --aprox;
            }

            else if (guessNewlinePos < pos) {
                // Current position is before the guessed newline

                // Check the position of the next newline to see if our pos is between them
                if (aprox + 1 == _newLines.length || _newLines[aprox + 1] > pos) {
                    return aprox + 1;
                }
                // Not found, continue searching front
                ++aprox;
            }
            else {
                assert(false, "Bug in currentLine");
            }
        }
    }
    public @safe @property
    ArrayIdx currentLine()
    {
        return lineAtPosition(gapStart);
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

    /**
     * [] (slice) operator, currently only supported as rvalue
     */

    /// OpIndex: BufferType b = gapbuffer[3];
    /// Please note that this returns a BufferType and NOT a single
    /// BufferElement because the returned character could take several code points/units.
    public const @safe pragma(inline)
    const(BufferType) opIndex(GrpmIdx pos)
    {
        // fast path
        if (_forceFastMode || !hasCombiningGraphemes)
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
    public const @safe pragma(inline)
    const(BufferType) opSlice(GrpmIdx start, GrpmIdx end)
    {
        // fast path
        if (_forceFastMode || !hasCombiningGraphemes) {
            return content[start.to!long..end.to!long];
        }

        // slow path
        return content.byGrapheme.drop(start.to!long)
                      .take(end.to!long - start.to!long)
                      .byCodePoint.array.to!(BufferType);
    }
    public const @safe pragma(inline)
    const(BufferType) opSlice(long start, long end)
    {
        return opSlice(start.GrpmIdx, end.GrpmIdx);
    }

    /**
     * index operator read: auto x = gapBuffer[]
     */
    public const pure nothrow @safe pragma(inline)
    const(BufferType) opSlice()
    {
        return content;
    }
}
