#!/usr/bin/python3
# -*- coding: utf-8 -*-

import sys, os
from pprint           import  pprint
from PyQt5.QtWidgets  import  QApplication
from PyQt5.QtGui      import  QFont, QFontMetrics, QColor
from PyQt5.QtCore     import  Qt, QEvent, QCoreApplication, pyqtSignal, pyqtSlot
from PyQt5.Qsci       import  QsciScintilla as QSci, QsciLexerPython
from enums            import  (EditorMode, Direction, SelectionMode, NUMSETKEYS,
                              ESCAPEFIRST, ESCAPESECOND, RETURN_LINES,
                              BACKSPACE_LINES)
from scitextops       import  SciTextOps


class NemeTextWidget(QSci):
    ARROW_MARKER_NUM = 0

    # Signals
    fileChanged     = pyqtSignal(str, name = 'fileChanged')
    fileSaved       = pyqtSignal(str, name = 'fileSaved')
    positionChanged = pyqtSignal(int, int, name = 'positionChanged')
    modeChanged     = pyqtSignal(int, name = 'modeChanged')

    # context manager for grouping several actions under a single undoable action
    class SingleUndo:
        def __init__(self, parent):
            self.parent = parent
        def __enter__(self):
            self.parent.beginUndoAction()
        def __exit__(self, type, value, traceback):
            self.parent.endUndoAction()


    # context manager for grouping several actions under a single undoable action
    # and do them with the scintilla component in read-write mode
    class ReadWriteSingleUndo:
        def __init__(self, parent):
            self.parent = parent
        def __enter__(self):
            self.parent.beginUndoAction()
            self.parent.setReadOnly(0)
        def __exit__(self, type, value, traceback):
            self.parent.endUndoAction()
            self.parent.setReadOnly(1)

    # context manager for doing several actions with the scintilla component in
    # read-write mode
    class ReadWrite:
        def __init__(self, parent):
            self.parent = parent
        def __enter__(self):
            self.parent.setReadOnly(0)
        def __exit__(self, type, value, traceback):
            self.parent.setReadOnly(1)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.textOps = SciTextOps(self)

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


    def _open(self, path):
        self.bufferFileName = path
        self.setText(open(self.bufferFileName, encoding='utf-8').read())
        self.setModified(False)
        self.fileChanged.emit(self.bufferFileName)


    def _save(self):
        if self.isModified():
            with open(self.bufferFileName, mode='wt', encoding='utf-8') as f:
                f.write(self.text())
                self.setModified(False)
                self.fileSaved.emit(self.bufferFileName)


    def _openWithDialog(self):
        # XXX FIXME: move to the parent window class
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
            self._save()

        if answer != QMessageBox.Cancel:
            fname = QFileDialog.getOpenFileName(self, 'Open file')
            if len(fname[0]):
                self._open(fname[0])


    def processNumberPrefix(self, key):
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


    def processFnKeyEvent(self, event):
        if event.key() == Qt.Key_F1: # save
            self._save()
        elif event.key() == Qt.Key_F2: # load file
            self._openWithDialog()
        elif event.key() == Qt.Key_F3: # save and exit
            self._save()
            QApplication.quit()


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
        self.modeChanged.emit(self.mode)


    def getModeAsString(self):
        return str(self.mode).split('.')[1]


    def processCommand(self):
        # FIXME: implement
        pass


    def keyPressEvent(self, e):
        process           = False # set to true to process the key at the end
        clearnumberList   = True
        modifiers         = QApplication.keyboardModifiers()

        if modifiers == Qt.GroupSwitchModifier:
            # altgr, just ignore it and get the e.text() where checked
            modifiers = Qt.NoModifier

        curLine, curIndex = self.getCursorPosition()

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
                elif e.key() in {Qt.Key_F1, Qt.Key_F2, Qt.Key_F3}:
                    self.processFnKeyEvent(e)
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
                else:
                    process = True
            else:
                process = True


        # =============================================================
        # Movement Mode
        # =============================================================
        elif self.mode == EditorMode.Movement:
            if modifiers in [Qt.NoModifier, Qt.ShiftModifier]: # NO MODIFIER
                if e.key() in NUMSETKEYS:
                    clearnumberList = self.processNumberPrefix(e.key())
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
                            self.textOps.insertLine(Direction.Below)
                        self.setMode(EditorMode.Typing)
                elif e.text() == 'O': # insert empty line above current
                    # FIXME: start at the right column after language indentation
                    with self.SingleUndo(self):
                        for _ in range(self.getNumberPrefix()):
                            self.textOps.insertLine(Direction.Above)
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
                        nextWordPos = self.textOps.findWORDPosition(Direction.Right)
                        if nextWordPos != -1:
                            self.SendScintilla(QSci.SCI_GOTOPOS, nextWordPos)
                elif e.text() == 'E': # next WORD end
                    for _ in range(self.getNumberPrefix()):
                        nextWordEndPos = self.textOps.findWORDPosition(Direction.Right)
                        if nextWordEndPos != -1:
                            self.SendScintilla(QSci.SCI_GOTOPOS, nextWordEndPos)
                            wordEnd = self.textOps.findWordEnd(WORD=True)
                            self.SendScintilla(QSci.SCI_GOTOPOS, wordEnd)
                elif e.text() == 'B': # prev WORD start
                    for _ in range(self.getNumberPrefix()):
                        prevWordEndPos = self.textOps.findWORDPosition(Direction.Left)
                        if prevWordEndPos != -1:
                            self.SendScintilla(QSci.SCI_GOTOPOS, prevWordEndPos)
                            wordStart = self.textOps.findWordStart(WORD=True)
                            self.SendScintilla(QSci.SCI_GOTOPOS, wordStart)
                elif e.text() == 'G': # go to the last line
                    self.SendScintilla(QSci.SCI_GOTOLINE, self.lines())
                elif e.text() == 'x': # delete char at the cursor (like the del key)
                    with self.ReadWriteSingleUndo(self):
                        num = self.getNumberPrefix()
                        self.setSelection(curLine, curIndex, curLine, curIndex+num)
                        self.cut()
                elif e.text() == 'X': # delete char before the cursor (like the backspace key)
                    with self.ReadWriteSingleUndo(self):
                        for _ in range(self.getNumberPrefix()):
                            self.SendScintilla(QSci.SCI_DELETEBACK)
                elif e.text() == '>': # indent
                    with self.ReadWriteSingleUndo(self):
                        for _ in range(self.getNumberPrefix()):
                            self.indent(curLine)
                            curLine += 1
                elif e.text() == '<': # unindent
                    with self.ReadWriteSingleUndo(self):
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
                            self.textOps.insertLine(Direction.Below)
                            self.paste()
                elif e.text() == 'f': # find char in line front
                    self.lineFindCharDirection = Direction.Right
                    self.setMode(EditorMode.FindChar)
                elif e.text() == 'F': # find char in line back
                    self.lineFindCharDirection = Direction.Left
                    self.setMode(EditorMode.FindChar)
                elif e.text() == ';': # repeat search of char in line
                    self.textOps.jumpToCharInLineFromPos(self.lineFindChar,
                                                  self.lineFindCharDirection)
                elif e.text() == ',': # repeat search of char in line in reverse direction
                    if self.lineFindCharDirection == Direction.Left:
                        revDirection = Direction.Right
                    else:
                        revDirection = Direction.Left
                    self.textOps.jumpToCharInLineFromPos(self.lineFindChar, revDirection)
                elif e.text() == 'd': # delete
                    if not self.hasNumberPrefix():
                        # FIXME start command line with 'd' pre-written
                        pass
                    else:
                        with self.ReadWrite(self):
                            self.textOps.deleteLines(Direction.Below)
                elif e.text() == 'D': # delete from cursor to EOL
                    with self.ReadWrite(self):
                        self.textOps.deleteToEOL()
                elif e.text() == 'c': # delete and change to typing mode
                    if not self.hasNumberPrefix():
                        # FIXME start command line with 'c' pre-written
                         pass
                    else:
                        with self.ReadWrite(self):
                            self.textOps.deleteLines(Direction.Below)
                            self.setMode(EditorMode.Typing)
                elif e.text() == 'C': # delete from cursor to EOL and change to typing mode
                    with self.ReadWrite(self):
                        self.textOps.deleteToEOL()
                        self.setMode(EditorMode.Typing)
                elif e.text() in ['y', 'Y']:
                    if self.selectionMode != SelectionMode.Disabled:
                        # with selection, both copy the selection
                        self.copy()
                        self.textOps.disableSelection()
                    elif e.text() == 'y':
                        # yank [prefix] lines or start yank command
                        if self.hasNumberPrefix():
                            self.textOps.yankLines(Direction.Below)
                        else:
                            # FIXME start command line with 'y' pre-written
                            pass
                    elif e.text() == 'Y':
                        # yank the current line
                        self.textOps.yankLines(Direction.Below)
                elif e.text() == 'v': # FIXME rethink 'v' for selection mode or call it visual
                    self.textOps.toggleSelection(SelectionMode.Character)
                elif e.text() == 'V': # select by line (FIXME: doesnt work)
                    self.textOps.toggleSelection(SelectionMode.Line)
                elif e.text() == '*': # find forward word under cursor
                    self.textOps.findWordUnderCursor()
                    self.lastSearchDirection = Direction.Below
                elif e.text() == '#': # find backward word under cursor
                    self.textOps.findWordUnderCursor(direction = Direction.Above)
                    self.lastSearchDirection = Direction.Above
                elif e.text() == 'n': # repeat last search in the same direction
                    self.textOps.repeatLastSearch(self.lastSearchDirection)
                elif e.text() == 'N': # repeat last search in reverse direction
                    if self.lastSearchDirection == Direction.Below:
                        direction = Direction.Above
                    else:
                        direction = Direction.Below
                    self.textOps.repeatLastSearch(direction)
                elif e.key() in {Qt.Key_F1, Qt.Key_F2, Qt.Key_F3}:
                    self.processFnKeyEvent(e)
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
                        prevWordEndPos = self.textOps.findWORDPosition(Direction.Left)
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
                        self.textOps.disableSelection()
                    else:
                        self.textOps.yankToEOL(fromLineStart = True)
                elif e.key() == Qt.Key_V:
                    # without selection, paste, with selection, change to rectagular mode
                    if self.selectionMode != SelectionMode.Disabled:
                        self.textOps.changeSelectionMode(SelectionMode.Rectangular)
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
                        line, index = self.getCursorPosition()
                        self.setSelection(line, index, line, index+1)
                        self.SendScintilla(QSci.SCI_CLEAR)
                        self.insertAt(e.text(), line, index)

                        if self.replaceModeRepeat > 1:
                            self.setCursorPosition(line, index+1)

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
                self.textOps.jumpToCharInLineFromPos(self.lineFindChar,
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

        # check the cursor position; if changed, emit the positionChanged signal
        endLine, endIndex = self.getCursorPosition()
        if endLine != curLine or endIndex != curIndex:
            self.positionChanged.emit(endLine, endIndex)
