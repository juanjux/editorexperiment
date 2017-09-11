from enums import *
from PyQt5.Qsci import QsciScintilla as QSci

SELMODE2SCISELMODE = {
            SelectionMode.Character   : QSci.SC_SEL_STREAM,
            SelectionMode.Line        : QSci.SC_SEL_LINES,
            SelectionMode.Rectangular : QSci.SC_SEL_RECTANGLE
}

class SciTextOps:
    """
    This object contains most operations done over a NemeTextWidget contained text, so it 
    should be easier to migrate to other Scintilla ports (gtk, text, windows, etc). As such, 
    Qt-isms should be contained as much as possible. This objects should not maintain any state;
    that should be in the widget. The only reason that the functions are not static is for 
    convenience so the constructor can get a nemetextwidget reference and methods can access
    it with a self access, but think of these methods as "pseudo-static".
    """

    def __init__(self, sciRef):
        self.sciRef = sciRef


    def findWORDPosition(self, direction):
        """
        Find next WORD start. With findRight=True it will
        instead find the end of the previous WORD
        """
        findRight       = (direction == Direction.Right)
        currentPos      = self.sciRef.SendScintilla(QSci.SCI_GETCURRENTPOS)
        char            = -1
        foundWhiteSpace = False
        adder = 1 if findRight else -1

        while (findRight and char != 0) or (not findRight and currentPos != 0):
            char = self.sciRef.SendScintilla(QSci.SCI_GETCHARAT, currentPos)
            if foundWhiteSpace and char not in WHITESPACE:
                # found the next word
                return currentPos

            if not foundWhiteSpace:
                foundWhiteSpace = char in WHITESPACE
            currentPos += adder
        return -1


    def findWordStart(self, WORD=False):
        """
        Find the start of the current word or WORD
        """
        currentPos = self.sciRef.SendScintilla(QSci.SCI_GETCURRENTPOS)
        while True:
            char = self.sciRef.SendScintilla(QSci.SCI_GETCHARAT, currentPos)
            if currentPos <= 0:
                return 0
            elif char in WHITESPACE or\
                 (not WORD and not self.sciRef.isWordCharacter(chr(char))):
                return currentPos + 1
            currentPos -= 1
        assert False


    def findWordEnd(self, WORD=False):
        """
        Find the end of the current word or WORD
        """

        currentPos = self.sciRef.SendScintilla(QSci.SCI_GETCURRENTPOS)
        lastPos = len(self.sciRef.text())
        while True:
            char = self.sciRef.SendScintilla(QSci.SCI_GETCHARAT, currentPos)
            if currentPos >= lastPos:
                return lastPos
            elif char in WHITESPACE or\
                 (not WORD and not self.sciRef.isWordCharacter(chr(char))):
                return currentPos - 1
            currentPos += 1
        assert False


    def getWordUnderCursor(self, WORD=False):
        """
        Return a tuple (startPos, endPos, text) if the cursor is not
        """
        wordStart = self.findWordStart(WORD)
        wordEnd   = self.findWordEnd(WORD)
        lastPos = len(self.sciRef.text())

        if wordStart > wordEnd or (wordStart == lastPos): # no word found or at the end
            return (-1, -1, '')

        if wordEnd == lastPos:
            wordEnd -= 1

        wordByteArray = bytearray(wordEnd - wordStart + 1)
        self.sciRef.SendScintilla(QSci.SCI_GETTEXTRANGE, wordStart, wordEnd + 1, wordByteArray)
        return (wordStart, wordEnd, wordByteArray.decode('utf-8'))


    def findText(self, text, startPos, endPos, searchFlags):
        if not len(text):
            return -1

        self.sciRef.SendScintilla(QSci.SCI_SETSEARCHFLAGS, searchFlags)
        self.sciRef.SendScintilla(QSci.SCI_SETTARGETSTART, startPos)
        self.sciRef.SendScintilla(QSci.SCI_SETTARGETEND, endPos)
        bytesText = text.encode('utf-8')
        return self.sciRef.SendScintilla(QSci.SCI_SEARCHINTARGET, len(bytesText), bytesText)


    def findWordUnderCursor(self, direction=Direction.Below):
        wordStart, wordEnd, word = self.getWordUnderCursor()
        if len(word):
            self.sciRef.lastSearchText = word
            textLength = len(self.sciRef.text())
            self.sciRef.lastSearchFlags = QSci.SCFIND_WHOLEWORD
            self.sciRef.SendScintilla(QSci.SCI_SETSEARCHFLAGS, self.sciRef.lastSearchFlags)
            if direction == Direction.Below:
                startPos = wordEnd
                endPos = textLength
                wrapStartPos = 0
                wrapEndPos = wordStart
            else:
                startPos = wordStart
                endPos = 0
                wrapStartPos = textLength
                wrapEndPos = wordEnd
            matchPosition = self.findText(word, startPos, endPos, self.sciRef.lastSearchFlags)

            if matchPosition == -1:
                matchPosition = self.findText(word, wrapStartPos,
                                               wrapEndPos, self.sciRef.lastSearchFlags)

            if matchPosition != -1:
                self.sciRef.SendScintilla(QSci.SCI_GOTOPOS, matchPosition)


    def repeatLastSearch(self, direction):
        currentPos = self.sciRef.SendScintilla(QSci.SCI_GETCURRENTPOS)
        textLength = len(self.sciRef.text())

        if direction == Direction.Below:
            startPos = currentPos + 1
            endPos = textLength
            wrapStartPos = 0
            wrapEndPos = startPos
        else:
            startPos = currentPos - 1
            endPos = 0
            wrapStartPos = textLength
            wrapEndPos = startPos
        pos = self.findText(self.sciRef.lastSearchText, startPos,
                             endPos, self.sciRef.lastSearchFlags)

        if pos == -1:
            pos = self.findText(self.sciRef.lastSearchText, wrapStartPos,
                                 wrapEndPos, self.sciRef.lastSearchFlags)
        if pos != -1:
            self.sciRef.SendScintilla(QSci.SCI_GOTOPOS, pos)


    def insertLine(self, direction):
        adder = 1 if (direction == Direction.Below) else 0
        line, index = self.sciRef.getCursorPosition()
        self.sciRef.insertAt('\n', line+adder, 0)
        self.sciRef.setCursorPosition(line+adder, 0)


    def jumpToCharInLineFromPos(self, char, direction):
        curLine, curIndex = self.sciRef.getCursorPosition()
        lineText = self.sciRef.text(curLine)

        if direction == Direction.Right:
            charPos = lineText.find(char, curIndex+1)
        else:
            charPos = lineText.rfind(char, 0, curIndex-1)

        if charPos != -1:
            self.sciRef.setCursorPosition(curLine, charPos)


    def selectLines(self, direction):
        multiplier = 1 if direction == Direction.Below else -1
        numLines = self.sciRef.getNumberPrefix(True)
        curLine, _ = self.sciRef.getCursorPosition()
        self.sciRef.setSelection(curLine, 0, curLine + (numLines * multiplier), 0)


    def selectToEOL(self):
        curLine, curIndex = self.sciRef.getCursorPosition()
        self.sciRef.setSelection(curLine, curIndex, curLine, self.sciRef.lineLength(curLine) - 1)


    def disableSelection(self):
        selStart = self.sciRef.SendScintilla(QSci.SCI_GETSELECTIONSTART)
        self.sciRef.SendScintilla(QSci.SCI_CLEARSELECTIONS)
        self.sciRef.SendScintilla(QSci.SCI_GOTOPOS, selStart)
        self.sciRef.selectionMode = SelectionMode.Disabled


    def changeSelectionMode(self, selectionMode):
        self.sciRef.selectionMode = selectionMode
        self.sciRef.SendScintilla(QSci.SCI_SETSELECTIONMODE,
                                  SELMODE2SCISELMODE[selectionMode])


    def toggleSelection(self, selectionMode):
        if self.sciRef.selectionMode != SelectionMode.Disabled:
            self.disableSelection()
        else:
            self.changeSelectionMode(selectionMode)


    def deleteLines(self, direction):
        self.selectLines(direction)
        self.sciRef.cut()


    def deleteToEOL(self):
        self.selectToEOL()
        self.sciRef.cut()


    def yankLines(self, direction):
        currentPos = self.sciRef.SendScintilla(QSci.SCI_GETCURRENTPOS)
        self.selectLines(direction)
        self.sciRef.copy()
        self.sciRef.SendScintilla(QSci.SCI_GOTOPOS, currentPos)


    def yankToEOL(self, fromLineStart = False):
        currentPos = self.sciRef.SendScintilla(QSci.SCI_GETCURRENTPOS)
        if fromLineStart:
            self.sciRef.SendScintilla(QSci.SCI_HOME)

        self.selectToEOL()
        self.sciRef.copy()
        self.sciRef.SendScintilla(QSci.SCI_GOTOPOS, currentPos)
