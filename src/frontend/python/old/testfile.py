#!/usr/bin/python3
# -*- coding: utf-8 -*-

"""
Neme Editor: a NEw Modal Editor prototype

author: Juanjo Álvarez

Objectives of this project:
    - have fun writing it when I don't have anything better to do
    - get up to date with Python3 and Qt5 (and C++ later, after prototyping)
    - have my own editor that I can modify easily to satisfy my needs
    - rethink the modal operation for modern keyboards hjkl => jikl, chord
      as default to exit typing (ex-insert) mode, etc.
    - don't use anything needing to press a modifier (not even shift) for basic operations
    - avoid symbols that usually need shift in non-us keyboards (like '/' to search
      or ':' to enter commands).
    - but have the alt/options key as an option for shortcuts too
    - use the function keys too
"""

"""
BUGS:
    - By Line selection doesnt seem to work (it does the same as by stream). I could workaround
      it or wait for an upstream fix or patch scintilla myself
    - Undo should restore the cursor at the line it was before the action that is being undo-ed
TODO:
    - i18n, string translations, file encodings other than UTF8, etc.
    - split this into several component classes, currently is mostly a Big Ugly class
    - make the command-keys configurable (currently: hardcoded)
"""

import sys, os, enum
from pprint import pprint


# FIXME: remove these *'s
from PyQt5.QtWidgets import *
from PyQt5.QtGui     import *
from PyQt5.QtCore    import Qt, QEvent, QCoreApplication, pyqtSignal
from PyQt5.Qsci      import QsciScintilla as QSci, QsciLexerPython

# FIXME: make these configurable
ESCAPEFIRST     = "k"
ESCAPESECOND    = "j"
BACKSPACE_LINES = 5
RETURN_LINES    = 5
NUMSETKEYS = {Qt.Key_0: '0', Qt.Key_1: '1', Qt.Key_2: '2', Qt.Key_3: '3',
              Qt.Key_4: '4', Qt.Key_5: '5', Qt.Key_6: '6', Qt.Key_7: '7',
              Qt.Key_8: '8', Qt.Key_9: '9'}
WHITESPACE = {32, 10, 13, 9}


class EditorMode(enum.Enum):
    Typing        = 1
    Movement      = 2
    Command       = 3
    ReplaceChar   = 4
    FindChar      = 5


class Direction(enum.Enum):
    Left  = 1
    Right = 2
    Above = 3
    Below = 4


class SelectionMode(enum.IntEnum):
    Disabled    = 1
    Character   = 2
    Line        = 3
    Rectangular = 4


class NemeTextWidget(QSci):
    ARROW_MARKER_NUM = 0

    # Signals
    fileChanged = pyqtSignal(str, name='fileChanged')

    def __init__(self, parent=None):
        super().__init__(parent)

        # number prefix storage
        self.numberList = []

        # font
        font = QFont()
        font.setFamily('Courier')
        font.setFixedPitch(True)
        font.setPointSize(10)
        self.setFont(font)
        fontmetrics = QFontMetrics(font)

        # margins
        self.setMarginsFont(font)
        self.setMarginWidth(0, fontmetrics.width("0000") + 3)
        self.setMarginLineNumbers(0, True)
        self.setMarginsBackgroundColor(QColor("#cccccc"))
        self.setMarginSensitivity(1, True)
        self.marginClicked.connect(self.on_margin_clicked)
        self.markerDefine(QSci.RightArrow, self.ARROW_MARKER_NUM)
        self.setMarkerBackgroundColor(QColor("#ee1111"), self.ARROW_MARKER_NUM)

        # Brace matching: enable for a brace immediately before or after
        # the current position
        #
        self.setBraceMatching(QSci.SloppyBraceMatch)

        # Current line visible with special background color
        self.setCaretLineVisible(True)
        self.setCaretLineBackgroundColor(QColor("#ffe4e4"))

        # Don't want to see the horizontal scrollbar at all
        # Use raw message to Scintilla here (all messages are documented
        # here: http://www.scintilla.org/ScintillaDoc.html)
        self.SendScintilla(QSci.SCI_SETHSCROLLBAR, 0)

        # Set Python lexer
        # Set style for Python comments (style number 1) to a fixed-width
        # courier.
        #
        lexer = QsciLexerPython()
        lexer.setDefaultFont(font)
        self.setLexer(lexer)

        #not too small
        self.setMinimumSize(600, 450)

        # Editor State Vars ====================================
        self.mode = None
        self.setMode(EditorMode.Movement)
        # used for kj escape secuence
        self.prevWasEscapeFirst = False
        # used to store the number argument before a replace (r) command
        self.replaceModeRepeat = 1
        # used to store the char to find in a line (f or F commands)
        self.lineFindChar = ''
        self.lineFindCharDirection = Direction.Right
        self.selectionMode = SelectionMode.Disabled
        self.lastSearchText = ''
        self.lastSearchDirection = Direction.Below
        self.lastSearchFlags = 0


    def _openWithDialog(self):
        if self.isModified():
            popup = QMessageBox(self)
            popup.setText('The file has been modified')
            popup.setInformativeText('Save changes?')
            popup.setStandardButtons(QMessageBox.Save   |
                                     QMessageBox.Cancel |
                                     QMessageBox.Discard)
            popup.setDefaultButton(QMessageBox.Save)
            answer = popup.exec_()
        else:
            answer = QMessageBox.Discard

        if answer == QMessageBox.Save:
            self._saveFile()

        if answer != QMessageBox.Cancel:
            fname = QFileDialog.getOpenFileName(self, 'Open file')
            if len(fname[0]):
                self.bufferFileName = fname[0]
                self.setText(open(self.bufferFileName, encoding='utf-8').read())
                self.setModified(False)
                self.fileChanged.emit(self.bufferFileName)


    def _findWORDPosition(self, direction):
        """
        Find next WORD start. With findRight=True it will
        instead find the end of the previous WORD
        """
        findRight       = (direction == Direction.Right)
        currentPos      = self.SendScintilla(QSci.SCI_GETCURRENTPOS)
        char            = -1
        foundWhiteSpace = False
        adder = 1 if findRight else -1

        while (findRight and char != 0) or (not findRight and currentPos != 0):
            char = self.SendScintilla(QSci.SCI_GETCHARAT, currentPos)
            if foundWhiteSpace and char not in WHITESPACE:
                # found the next word
                return currentPos

            if not foundWhiteSpace:
                foundWhiteSpace = char in WHITESPACE
            currentPos += adder
        return -1


    def _findWordStart(self, WORD=False):
        """
        Find the start of the current word or WORD
        """
        currentPos = self.SendScintilla(QSci.SCI_GETCURRENTPOS)
        while True:
            char = self.SendScintilla(QSci.SCI_GETCHARAT, currentPos)
            if currentPos <= 0:
                return 0
            elif char in WHITESPACE or (not WORD and not self.isWordCharacter(chr(char))):
                return currentPos + 1
            currentPos -= 1
        assert False


    def _findWordEnd(self, WORD=False):
        """
        Find the end of the current word or WORD
        """

        currentPos = self.SendScintilla(QSci.SCI_GETCURRENTPOS)
        lastPos = len(self.text())
        while True:
            char = self.SendScintilla(QSci.SCI_GETCHARAT, currentPos)
            if currentPos >= lastPos:
                return lastPos
            elif char in WHITESPACE or (not WORD and not self.isWordCharacter(chr(char))):
                return currentPos - 1
            currentPos += 1
        assert False


    def _getWordUnderCursor(self, WORD=False):
        """
        Return a tuple (startPos, endPos, text) if the cursor is not
        """
        wordStart = self._findWordStart(WORD)
        wordEnd   = self._findWordEnd(WORD)
        lastPos = len(self.text())

        if wordStart > wordEnd or (wordStart == lastPos): # no word found or at the end
            return (-1, -1, '')

        if wordEnd == lastPos:
            wordEnd -= 1

        wordByteArray = bytearray(wordEnd - wordStart + 1)
        self.SendScintilla(QSci.SCI_GETTEXTRANGE, wordStart, wordEnd + 1, wordByteArray)
        return (wordStart, wordEnd, wordByteArray.decode('utf-8'))


    def _findText(self, text, startPos, endPos, searchFlags):
        if not len(text):
            return -1

        self.SendScintilla(QSci.SCI_SETSEARCHFLAGS, searchFlags)
        self.SendScintilla(QSci.SCI_SETTARGETSTART, startPos)
        self.SendScintilla(QSci.SCI_SETTARGETEND, endPos)
        bytesText = text.encode('utf-8')
        return self.SendScintilla(QSci.SCI_SEARCHINTARGET, len(bytesText), bytesText)


    def _findWordUnderCursor(self, direction=Direction.Below):
        wordStart, wordEnd, word = self._getWordUnderCursor()
        if len(word):
            self.lastSearchText = word
            textLength = len(self.text())
            self.lastSearchFlags = QSci.SCFIND_WHOLEWORD
            self.SendScintilla(QSci.SCI_SETSEARCHFLAGS, self.lastSearchFlags)
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
            matchPosition = self._findText(word, startPos, endPos, self.lastSearchFlags)

            if matchPosition == -1:
                matchPosition = self._findText(word, wrapStartPos,
                                               wrapEndPos, self.lastSearchFlags)

            if matchPosition != -1:
                self.SendScintilla(QSci.SCI_GOTOPOS, matchPosition)


    def _repeatLastSearch(self, direction):
        currentPos = self.SendScintilla(QSci.SCI_GETCURRENTPOS)
        textLength = len(self.text())

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
        pos = self._findText(self.lastSearchText, startPos,
                             endPos, self.lastSearchFlags)

        if pos == -1:
            pos = self._findText(self.lastSearchText, wrapStartPos,
                                 wrapEndPos, self.lastSearchFlags)
        if pos != -1:
            self.SendScintilla(QSci.SCI_GOTOPOS, pos)


    def _processNumberPrefix(self, key):
        "This should be called only when key has been validated to be a member of NUMSETKEYS"

        strnumkey = NUMSETKEYS.get(key)
        haveToClearList = False

        if strnumkey == '0' and not len(self.numberList):
            # store 0s only when not the first
            self.numberList.clear()
            haveToClearList = True
        else:
            self.numberList.append(strnumkey)

        print('DEBUG: number buffer: {}'.format(self.numberList))
        return haveToClearList


    def _insertLine(self, direction):
        adder = 1 if (direction == Direction.Below) else 0
        line, index = self.getCursorPosition()
        self.insertAt('\n', line+adder, 0)
        self.setCursorPosition(line+adder, 0)


    def _jumpToCharInLineFromPos(self, char, direction):
        curLine, curIndex = self.getCursorPosition()
        lineText = self.text(curLine)

        if direction == Direction.Right:
            charPos = lineText.find(char, curIndex+1)
        else:
            charPos = lineText.rfind(char, 0, curIndex-1)

        if charPos != -1:
            self.setCursorPosition(curLine, charPos)


    def _selectLines(self, direction):
        multiplier = 1 if direction == Direction.Below else -1
        numLines = self.getNumberPrefix(True)
        curLine, _ = self.getCursorPosition()
        self.setSelection(curLine, 0, curLine + (numLines * multiplier), 0)


    def _selectToEOL(self):
        curLine, curIndex = self.getCursorPosition()
        self.setSelection(curLine, curIndex, curLine, self.lineLength(curLine) - 1)


    def _disableSelection(self):
        selStart = self.SendScintilla(QSci.SCI_GETSELECTIONSTART)
        self.SendScintilla(QSci.SCI_CLEARSELECTIONS)
        self.SendScintilla(QSci.SCI_GOTOPOS, selStart)
        self.selectionMode = SelectionMode.Disabled


    def _deleteLines(self, direction):
        self._selectLines(direction)
        self.cut()


    def _deleteToEOL(self):
        self._selectToEOL()
        self.cut()


    def _yankLines(self, direction):
        currentPos = self.SendScintilla(QSci.SCI_GETCURRENTPOS)
        self._selectLines(direction)
        self.copy()
        self.SendScintilla(QSci.SCI_GOTOPOS, currentPos)


    def _yankToEOL(self, fromLineStart = False):
        currentPos = self.SendScintilla(QSci.SCI_GETCURRENTPOS)
        if fromLineStart:
            self.SendScintilla(QSci.SCI_HOME)

        self._selectToEOL()
        self.copy()
        self.SendScintilla(QSci.SCI_GOTOPOS, currentPos)


    class SingleUndo:
        def __init__(self, parent):
            self.parent = parent
        def __enter__(self):
            self.parent.beginUndoAction()
        def __exit__(self, type, value, traceback):
            self.parent.endUndoAction()


    class ReadWriteSingleUndo:
        def __init__(self, parent):
            self.parent = parent
        def __enter__(self):
            self.parent.beginUndoAction()
            self.parent.setReadOnly(0)
        def __exit__(self, type, value, traceback):
            self.parent.endUndoAction()
            self.parent.setReadOnly(1)



    class ReadWrite:
        def __init__(self, parent):
            self.parent = parent
        def __enter__(self):
            self.parent.setReadOnly(0)
        def __exit__(self, type, value, traceback):
            self.parent.setReadOnly(1)


    def hasNumberPrefix(self):
        return bool(len(self.numberList))


    def getNumberPrefix(self, limitByMaxLines = False):
        if not self.numberList:
            number = 1
        else:
            number = int(''.join([str(i) for i in self.numberList]))
        if limitByMaxLines:
            number = min(number, self.lines())
        return number


    def on_margin_clicked(self, nmargin, nline, modifiers):
        # Toggle marker for the line the margin was clicked on
        if self.markersAtLine(nline) != 0:
            self.markerDelete(nline, self.ARROW_MARKER_NUM)
        else:
            self.markerAdd(nline, self.ARROW_MARKER_NUM)


    def setMode(self, newmode):
        # TODO: Change cursor color on special modes?
        if newmode == self.mode:
            return

        if newmode == EditorMode.Typing:
            self.SendScintilla(QSci.SCI_SETCARETSTYLE, 1)
            self.setReadOnly(0)
        elif newmode == EditorMode.Movement:
            self.SendScintilla(QSci.SCI_SETCARETSTYLE, 2)
            self.setReadOnly(1)
        elif newmode == EditorMode.Command:
            self.setReadOnly(1)
        elif newmode == EditorMode.ReplaceChar:
            self.SendScintilla(QSci.SCI_SETCARETSTYLE, 1)
            self.setReadOnly(1)
        elif newmode == EditorMode.FindChar:
            self.setReadOnly(1)

        self.mode = newmode
        print('NewMode: {}'.format(self.mode))


    def processCommand(self):
        # FIXME: implement
        pass


    def keyPressEvent(self, e):
        process         = False # set to true to process the key at the end
        clearnumberList = True
        modifiers       = QApplication.keyboardModifiers()

        # =============================================================
        # Typing Mode
        # =============================================================
        if self.mode == EditorMode.Typing:
            if modifiers in [Qt.NoModifier, Qt.ShiftModifier]:
                if e.key() == Qt.Key_Escape:
                    self.setMode(EditorMode.Movement)
                elif e.text() == ESCAPEFIRST:
                    self.prevWasEscapeFirst = True
                    process = True

                elif e.text() == ESCAPESECOND:
                    if self.prevWasEscapeFirst: # delete previous K and change to Movement
                        self.SendScintilla(QSci.SCI_DELETEBACK)
                        self.setMode(EditorMode.Movement)
                    else:
                        process = True
                    self.prevWasEscapeFirst = False
                elif e.key() == Qt.Key_F1: # save
                    self._save()
                elif e.key() == Qt.Key_F2: # load file
                    self._openWithDialog()
                else:
                    # just write
                    process = True

            elif modifiers == Qt.ControlModifier: # CONTROL
                # Ctrl + IK is PageUP/Down too like in normal mode
                if e.key() == Qt.Key_I:
                    self.SendScintilla(QSci.SCI_PAGEUP)
                elif e.key() == Qt.Key_K:
                    self.SendScintilla(QSci.SCI_PAGEDOWN)

            elif modifiers == Qt.AltModifier: # ALT
                # Alt + IKJL also moves the cursor in typing mode
                if e.key() == Qt.Key_I:
                    self.SendScintilla(QSci.SCI_LINEUP)
                elif e.key() == Qt.Key_K:
                    self.SendScintilla(QSci.SCI_LINEDOWN)
                elif e.key() == Qt.Key_J:
                    self.SendScintilla(QSci.SCI_CHARLEFT)
                elif e.key() == Qt.Key_L:
                    self.SendScintilla(QSci.SCI_CHARRIGHT)

        # =============================================================
        # Movement Mode
        # =============================================================
        elif self.mode == EditorMode.Movement:
            if modifiers in [Qt.NoModifier, Qt.ShiftModifier]: # NO MODIFIER
                if e.key() in NUMSETKEYS:
                    clearnumberList = self._processNumberPrefix(e.key())
                    if e.text() == '0' and clearnumberList:
                        # 0 with buffer empty = goto beginning of line
                        self.SendScintilla(QSci.SCI_HOME)

                elif e.text() == 't': # enter typing mode
                    self.setMode(EditorMode.Typing)

                elif e.text() == 'a': # enter typing mode after the current char
                    self.SendScintilla(QSci.SCI_CHARRIGHT)
                    self.setMode(EditorMode.Typing)

                elif e.key() == Qt.Key_Space:
                    self.setMode(EditorMode.Command)

                elif e.text() == 'i': # line up
                    if modifiers == Qt.ControlModifier:
                        for _ in range(self.getNumberPrefix(True)):
                            self.SendScintilla(QSci.SCI_PAGEUP)
                    else:
                        for _ in range(self.getNumberPrefix(True)):
                            self.SendScintilla(QSci.SCI_LINEUP)
                elif e.key() == Qt.Key_Backspace: # n lines up
                    for _ in range(BACKSPACE_LINES * self.getNumberPrefix(True)):
                        self.SendScintilla(QSci.SCI_LINEUP, 5)
                elif e.text() == 'k': # line down
                    if modifiers == Qt.ControlModifier:
                        for _ in range(self.getNumberPrefix(True)):
                            self.SendScintilla(QSci.SCI_PAGEDOWN)
                    else:
                        for _ in range(self.getNumberPrefix(True)):
                            self.SendScintilla(QSci.SCI_LINEDOWN)
                elif e.key() == Qt.Key_Return: # n lines up
                    # FIXME: Do the right way of goto_line (current - 5)
                    for _ in range(RETURN_LINES * self.getNumberPrefix(True)):
                        self.SendScintilla(QSci.SCI_LINEDOWN, 5)
                elif e.text() == 'j': # char left
                    for _ in range(self.getNumberPrefix()):
                        self.SendScintilla(QSci.SCI_CHARLEFT)
                elif e.text() == 'l': # char right
                    for _ in range(self.getNumberPrefix()):
                        self.SendScintilla(QSci.SCI_CHARRIGHT)
                elif e.text() == 'w': # next beginning of word
                    for _ in range(self.getNumberPrefix()):
                        self.SendScintilla(QSci.SCI_WORDRIGHT)
                elif e.text() == 'b': # prev beginning of word
                    for _ in range(self.getNumberPrefix()):
                        self.SendScintilla(QSci.SCI_WORDLEFT)
                elif e.text() == 'e': # next end of word
                    for _ in range(self.getNumberPrefix()):
                        self.SendScintilla(QSci.SCI_CHARRIGHT)
                        self.SendScintilla(QSci.SCI_WORDRIGHTEND)
                        self.SendScintilla(QSci.SCI_CHARLEFT)
                elif e.text() == 'u': # undo
                    with self.ReadWrite(self):
                        for _ in range(self.getNumberPrefix()):
                            self.undo()
                elif e.text() == 's': # first non-blank in line
                    self.SendScintilla(QSci.SCI_VCHOME)
                elif e.text() == 'o': # insert empty line below current
                    with self.SingleUndo(self):
                        # FIXME: start at the right column after language indentation
                        for _ in range(self.getNumberPrefix()):
                            self._insertLine(Direction.Below)
                        self.setMode(EditorMode.Typing)
                elif e.text() == 'O': # insert empty line above current
                    # FIXME: start at the right column after language indentation
                    with self.SingleUndo(self):
                        for _ in range(self.getNumberPrefix()):
                            self._insertLine(Direction.Above)
                        self.setMode(EditorMode.Typing)
                elif e.text() == 'g': # goto line, only with numeric prefix
                    if not self.hasNumberPrefix():
                        # FIXME start command line with 'g' command pre-written
                        pass
                    else:
                        line = self.getNumberPrefix(True)
                        self.SendScintilla(QSci.SCI_GOTOLINE, line-1)
                elif e.text() == 'r':
                    self.replaceModeRepeat = self.getNumberPrefix()
                    self.setMode(EditorMode.ReplaceChar)
                elif e.text() == '$': # end of line
                    self.SendScintilla(QSci.SCI_LINEEND)
                    self.SendScintilla(QSci.SCI_CHARLEFT)
                elif e.text() == 'A': # append after EOL
                    self.SendScintilla(QSci.SCI_LINEEND)
                    self.setMode(EditorMode.Typing)
                elif e.text() == 'I': # insert at the start of the line
                    self.SendScintilla(QSci.SCI_VCHOME)
                    self.setMode(EditorMode.Typing)
                elif e.text() == 'J': # join line with line below
                    # FIXME: undoing this leaves the cursor at the end of the line
                    with self.ReadWriteSingleUndo(self):
                        for _ in range(self.getNumberPrefix(True)):
                            line, index = self.getCursorPosition()
                            nextLine    = self.text(line + 1).lstrip()
                            if not nextLine:
                                nextLine = '\n'

                            self.insertAt(' ' + nextLine, line, self.lineLength(line)-1)
                            self.SendScintilla(QSci.SCI_LINEDOWN)
                            self.SendScintilla(QSci.SCI_LINEDELETE)
                            self.SendScintilla(QSci.SCI_LINEDELETE)
                            self.SendScintilla(QSci.SCI_LINEUP)
                elif e.text() == 'W': # next WORD
                    for _ in range(self.getNumberPrefix()):
                        nextWordPos = self._findWORDPosition(Direction.Right)
                        if nextWordPos != -1:
                            self.SendScintilla(QSci.SCI_GOTOPOS, nextWordPos)
                elif e.text() == 'E': # next WORD end
                    for _ in range(self.getNumberPrefix()):
                        nextWordEndPos = self._findWORDPosition(Direction.Right)
                        if nextWordEndPos != -1:
                            self.SendScintilla(QSci.SCI_GOTOPOS, nextWordEndPos)
                            wordEnd = self._findWordEnd(WORD=True)
                            self.SendScintilla(QSci.SCI_GOTOPOS, wordEnd)
                elif e.text() == 'B': # prev WORD start
                    for _ in range(self.getNumberPrefix()):
                        prevWordEndPos = self._findWORDPosition(Direction.Left)
                        if prevWordEndPos != -1:
                            self.SendScintilla(QSci.SCI_GOTOPOS, prevWordEndPos)
                            wordStart = self._findWordStart(WORD=True)
                            self.SendScintilla(QSci.SCI_GOTOPOS, wordStart)
                elif e.text() == 'G': # go to the last line
                    self.SendScintilla(QSci.SCI_GOTOLINE, self.lines())
                elif e.text() == 'x': # delete char at the cursor (like the del key)
                    with self.ReadWriteSingleUndo(self):
                        num = self.getNumberPrefix()
                        curLine, curIndex = self.getCursorPosition()
                        self.setSelection(curLine, curIndex, curLine, curIndex+num)
                        self.cut()
                elif e.text() == 'X': # delete char before the cursor (like the backspace key)
                    with self.ReadWriteSingleUndo(self):
                        for _ in range(self.getNumberPrefix()):
                            self.SendScintilla(QSci.SCI_DELETEBACK)
                elif e.text() == '>': # indent
                    with self.ReadWriteSingleUndo(self):
                        curLine, _ = self.getCursorPosition()
                        for _ in range(self.getNumberPrefix()):
                            self.indent(curLine)
                            curLine += 1
                elif e.text() == '<': # unindent
                    with self.ReadWriteSingleUndo(self):
                        curLine, _ = self.getCursorPosition()
                        for _ in range(self.getNumberPrefix()):
                            self.unindent(curLine)
                            curLine += 1
                elif e.text() == 'p': # paste at cursor position
                    with self.ReadWriteSingleUndo(self):
                        for _ in range(self.getNumberPrefix()):
                            self.paste()
                elif e.text() == 'P': # paste on a new line below cursor position
                    with self.ReadWriteSingleUndo(self):
                        for _ in range(self.getNumberPrefix()):
                            self._insertLine(Direction.Below)
                            self.paste()
                elif e.text() == 'f': # find char in line front
                    self.lineFindCharDirection = Direction.Right
                    self.setMode(EditorMode.FindChar)
                elif e.text() == 'F': # find char in line back
                    self.lineFindCharDirection = Direction.Left
                    self.setMode(EditorMode.FindChar)
                elif e.text() == ';': # repeat search of char in line
                    self._jumpToCharInLineFromPos(self.lineFindChar,
                                                  self.lineFindCharDirection)
                elif e.text() == ',': # repeat search of char in line in reverse direction
                    if self.lineFindCharDirection == Direction.Left:
                        revDirection = Direction.Right
                    else:
                        revDirection = Direction.Left
                    self._jumpToCharInLineFromPos(self.lineFindChar, revDirection)
                elif e.text() == 'd': # delete
                    if not self.hasNumberPrefix():
                        # FIXME start command line with 'd' pre-written
                        pass
                    else:
                        with self.ReadWrite(self):
                            self._deleteLines(Direction.Below)
                elif e.text() == 'D': # delete from cursor to EOL
                    with self.ReadWrite(self):
                        self._deleteToEOL()
                elif e.text() == 'c': # delete and change to typing mode
                    if not self.hasNumberPrefix():
                        # FIXME start command line with 'c' pre-written
                         pass
                    else:
                        with self.ReadWrite(self):
                            self._deleteLines(Direction.Below)
                            self.setMode(EditorMode.Typing)
                elif e.text() == 'C': # delete from cursor to EOL and change to typing mode
                    with self.ReadWrite(self):
                        self._deleteToEOL()
                        self.setMode(EditorMode.Typing)
                elif e.text() in ['y', 'Y']:
                    if self.selectionMode != SelectionMode.Disabled:
                        # with selection, both copy the selection
                        self.copy()
                        self._disableSelection()
                    elif e.text() == 'y':
                        # yank [prefix] lines or start yank command
                        if self.hasNumberPrefix():
                            self._yankLines(Direction.Below)
                        else:
                            # FIXME start command line with 'y' pre-written
                            pass
                    elif e.text() == 'Y':
                        # yank the current line
                        self._yankLines(Direction.Below)
                        #self._yankToEOL(fromLineStart = True)
                elif e.text() == 'v': # FIXME rethink 'v' for selection mode or call it visual
                    if self.selectionMode != SelectionMode.Disabled:
                        self._disableSelection()
                    else:
                        self.selectionMode = SelectionMode.Character
                        self.SendScintilla(QSci.SCI_SETSELECTIONMODE, QSci.SC_SEL_STREAM)
                elif e.text() == 'V': # select by line (FIXME: doesnt work)
                    if self.selectionMode != SelectionMode.Disabled:
                        self._disableSelection()
                    else:
                        self.selectionMode = SelectionMode.Line
                        self.SendScintilla(QSci.SCI_SETSELECTIONMODE, QSci.SC_SEL_LINES)
                elif e.text() == '*': # find forward word under cursor
                    self._findWordUnderCursor()
                    self.lastSearchDirection = Direction.Below
                elif e.text() == '#': # find backward word under cursor
                    self._findWordUnderCursor(direction = Direction.Above)
                    self.lastSearchDirection = Direction.Above
                elif e.text() == 'n': # repeat last search in the same direction
                    self._repeatLastSearch(self.lastSearchDirection)
                elif e.text() == 'N': # repeat last search in reverse direction
                    if self.lastSearchDirection == Direction.Below:
                        direction = Direction.Above
                    else:
                        direction = Direction.Below
                    self._repeatLastSearch(direction)
                elif e.key() == Qt.Key_F1: # save
                    # XXX implement 
                    self._save()
                elif e.key() == Qt.Key_F2: # load file
                    self._openWithDialog()
                else:
                    # probably single modifier key pressed
                    clearnumberList = False

            elif modifiers == Qt.AltModifier: # ALT
                if e.key() == Qt.Key_E: # prev end of word
                    for _ in range(self.getNumberPrefix()):
                        self.SendScintilla(QSci.SCI_WORDLEFTEND)
                        self.SendScintilla(QSci.SCI_CHARLEFT)
                elif e.key() == Qt.Key_B: # prev end of WORD
                    for _ in range(self.getNumberPrefix()):
                        prevWordEndPos = self._findWORDPosition(Direction.Left)
                        self.SendScintilla(QSci.SCI_GOTOPOS, prevWordEndPos)
                elif e.key() == Qt.Key_U: # redo
                    with self.ReadWrite(self):
                        for _ in range(self.getNumberPrefix()):
                            self.redo()

            elif modifiers == Qt.ControlModifier:# CONTROL
                if e.key() == Qt.Key_I: # page up
                    for _ in range(self.getNumberPrefix(True)):
                        self.SendScintilla(QSci.SCI_PAGEUP)
                elif e.key() == Qt.Key_K: # page down
                    for _ in range(self.getNumberPrefix(True)):
                        self.SendScintilla(QSci.SCI_PAGEDOWN)
                elif e.key() == Qt.Key_C:
                    # with selection, copy selection
                    # without selection but with prefix, yank [prefix] lines, like 'y'
                    # without selection or prefix, copy the full line, like 'Y'
                    if self.selectionMode != SelectionMode.Disabled:
                        self.copy()
                        self._disableSelection()
                    else:
                        self._yankToEOL(fromLineStart = True)
                elif e.key() == Qt.Key_V:
                    # without selection, paste, with selection, change to rectagular mode
                    if self.selectionMode != SelectionMode.Disabled:
                        self.selectionMode = SelectionMode.Rectangular
                        self.SendScintilla(QSci.SCI_SETSELECTIONMODE, QSci.SC_SEL_RECTANGLE)
                    else:
                        with self.ReadWriteSingleUndo(self):
                            for _ in range(self.getNumberPrefix()):
                                self.paste()


        # ==============================================================
        # Command Mode
        # ==============================================================
        elif self.mode == EditorMode.Command:
            if e.key() == Qt.Key_Escape:
                self.setMode(EditorMode.Movement)

            elif e.key() == Qt.Key_Return:
                self.processCommand()
                self.setMode(EditorMode.Movement)

        # ==============================================================
        # ReplaceChar Mode
        # ==============================================================
        elif self.mode == EditorMode.ReplaceChar:
            if e.key() == Qt.Key_Escape:
                self.setMode(EditorMode.Movement)
            elif not e.text():
                pass
            else:
                with self.ReadWriteSingleUndo(self):
                    for _ in range(self.replaceModeRepeat):
                        curLine, curIndex = self.getCursorPosition()
                        self.setSelection(curLine, curIndex, curLine, curIndex+1)
                        self.SendScintilla(QSci.SCI_CLEAR)
                        self.insertAt(e.text(), curLine, curIndex)

                        if self.replaceModeRepeat > 1:
                            self.setCursorPosition(curLine, curIndex+1)

                self.replaceModeRepeat = 1
                self.setMode(EditorMode.Movement)

        # ==============================================================
        # Find Char Front Mode
        # ==============================================================
        elif self.mode == EditorMode.FindChar:
            if e.key() == Qt.Key_Escape:
                self.setMode(EditorMode.Movement)
            elif not e.text():
                pass
            else:
                self.lineFindChar = e.text()
                self._jumpToCharInLineFromPos(self.lineFindChar,
                                              self.lineFindCharDirection)
                self.setMode(EditorMode.Movement)

        if self.prevWasEscapeFirst and e.text() != ESCAPEFIRST:
            # clear the escape chord if the second char doesnt follows the first
            self.prevWasEscapeFirst = False

        if clearnumberList:
            # clearnumberList is set to false when the char is a number
            self.numberList.clear()

        if process:
            super().keyPressEvent(e)


class Neme(QMainWindow):

    def __init__(self):
        super().__init__()
        self.initUI()


    def initUI(self):
        self.scintilla = NemeTextWidget()
        self.scintilla.setText(
                open(os.path.abspath('testfile.py'),
                     encoding="utf8").read()
        )
        self.scintilla.setModified(False)
        self.setCentralWidget(self.scintilla)
        self.setGeometry(300, 300, 350, 250)
        self.scintilla.fileChanged.connect(self.handleFileChange)
        self.show()

    def handleFileChange(self, fname):
        self.setWindowTitle('Neme - {}'.format(fname))


if __name__ == '__main__':
    app = QApplication(sys.argv)
    neme = Neme()
    sys.exit(app.exec_())
