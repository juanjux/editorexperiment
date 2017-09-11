#!/usr/bin/python3
# -*- coding: utf-8 -*-

"""
Neme: a NEw Modal Editor prototype

author: Juanjo Álvarez

Objectives of this project:
    - have fun writing it when I don't have anything better to do
    - get up to date with Python3 and Qt5 (and C++ later, after prototyping)
    - have my own editor that I can modify easily to satisfy my needs
    - rethink the modal operation for modern keyboards hjkl => jikl, chord
      as default to exit typing (ex-insert) mode.
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
    - Think if I want alt+motionKey always be the reverse of motionKey
    - i18n, string translations, file encodings other than UTF8, etc.
    - make the command-keys configurable (currently: hardcoded)
"""

import sys, os
from pprint import pprint # noqa: F401
from PyQt5.QtWidgets import QMainWindow, QApplication
from PyQt5.QtCore import pyqtSlot
from nemetextwidget import NemeTextWidget


class Neme(QMainWindow):

    def __init__(self):
        super().__init__()
        self.initUI()
        self.textComponent.fileSaved.connect(self.handleFileSave)
        self.textComponent.positionChanged.connect(self.updateStatusBar)
        self.textComponent.modeChanged.connect(self.updateStatusBar)


    def initUI(self):
        self.textComponent = NemeTextWidget()
        self.textComponent.fileChanged.connect(self.handleFileChange)
        self.textComponent._open(os.path.abspath('testfile.py'))
        self.textComponent.setModified(False)
        self.setCentralWidget(self.textComponent)
        self.setGeometry(300, 300, 350, 250)
        self.show()


    @pyqtSlot(str)
    def handleFileChange(self, fname):
        self.setWindowTitle('Neme - {}'.format(fname))
        self.statusBar().showMessage('File changed to {}'.format(fname))


    @pyqtSlot(str)
    def handleFileSave(self, fname):
        self.statusBar().showMessage('File saved to: {}'.format(fname))


    @pyqtSlot(int)
    def updateStatusBar(self):
        line, index = self.textComponent.getCursorPosition()
        totalLines = self.textComponent.lines()
        if totalLines == 0:
            totalLines = 1 # protect against 0divisions

        statusLineParams = {
                'line': line,
                'index': index,
                'mode': self.textComponent.getModeAsString(),
                'fnameBase': os.path.basename(self.textComponent.bufferFileName),
                'percent': int(((line + 1)/ totalLines) * 100)
        }
        self.statusBar().showMessage('{mode} | {fnameBase} | {percent} | {line}.{index}'
                                     .format(**statusLineParams))


if __name__ == '__main__':
    app = QApplication(sys.argv)
    neme = Neme()
    sys.exit(app.exec_())
