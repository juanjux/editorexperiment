module neme.core.extractors;

import neme.core.gapbuffer;
import neme.core.predicates;
import neme.core.settings;
import neme.core.types;

import std.algorithm.comparison : min;
import std.conv;
import std.stdio;
import std.array;

public @safe
const(Subject)[] lines(in GapBuffer gb, GrpmIdx startPos, Direction dir,
                       ArraySize count, Predicate predicate = &All)
{
    const(Subject)[] lines;
    immutable goingForward = dir == Direction.Front;
    ulong iterated;

    auto lineStartPos = gb.grpmPos2CPPos(startPos);
    auto lineno = gb.lineNumAtPos(lineStartPos);
    auto limitFound = () => (goingForward && lineno > gb.numLines) || (!goingForward && lineno < 1);

    while (iterated < count && !limitFound())
    {
        auto line = gb.lineArraySubject(lineno).toSubject(gb);

        if (predicate(line)) {
            lines ~= line;
            ++iterated;
        }

        goingForward ? ++lineno : --lineno;
    }

    return lines;
}

public @safe
const(Subject)[] words(in GapBuffer gb, GrpmIdx startPos, Direction dir,
                    ArraySize count, Predicate predicate = &All)
{
    import std.container.dlist: DList;

    immutable contentLen = gb.contentGrpmLen;
    if (contentLen == 0)
        return [];

    const(Subject)[] words; words.reserve(count);
    auto pos = startPos;
    auto wordStartPos = pos;
    auto curWord = DList!BufferElement();
    immutable goingForward = (dir == Direction.Front);
    ulong iterated;

    void maybeAddWord() {
        GrpmIdx realStart, realEnd;

        if (goingForward) {
            realStart = wordStartPos;
            realEnd = GrpmIdx(pos - 1);
        } else {
            realStart = GrpmIdx(pos + 1);
            realEnd = wordStartPos;
        }

        auto word = Subject(realStart, realEnd, curWord.array);
        if (predicate(word)) {
            words ~= word;
            ++iterated;
        }

        curWord.clear();
    }

    bool prevWasWordChar;
    auto limitFound = () => (goingForward && pos >= contentLen) || (!goingForward && pos < 0);

    while (iterated < count) {
        const(BufferType) curGrpm = gb[pos.to!long];
        bool isWordChar = true;

        foreach(BufferElement cp; curGrpm) {
            // FIXME XXX: any sequence of wordSeparators started by a wordSeparator char is also a word
            // until the first non separator or whitespace character
            if (cp in globalSettings.wordSeparators) {
                isWordChar = false;
                break;
            }
        }

        if (isWordChar) {
            goingForward ? curWord.insertBack(curGrpm) : curWord.insertFront(curGrpm);

            if (!prevWasWordChar) // start of new word
                wordStartPos = pos;
        } else if (prevWasWordChar)  // end of the word
            maybeAddWord;

        goingForward ? ++pos : --pos;

        if (limitFound()) {
            if (isWordChar)
                maybeAddWord;
            break;
        }

        prevWasWordChar = isWordChar;
    }

    return words;
}
