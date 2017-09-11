import enum
from PyQt5.QtCore import Qt

class EditorMode(enum.Enum):
    Typing      = 1
    Movement    = 2
    Command     = 3
    ReplaceChar = 4
    FindChar    = 5


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


# FIXME: make these configurable
ESCAPEFIRST     = "k"
ESCAPESECOND    = "j"
BACKSPACE_LINES = 5
RETURN_LINES    = 5
NUMSETKEYS = {Qt.Key_0: '0', Qt.Key_1: '1', Qt.Key_2: '2', Qt.Key_3: '3',
              Qt.Key_4: '4', Qt.Key_5: '5', Qt.Key_6: '6', Qt.Key_7: '7',
              Qt.Key_8: '8', Qt.Key_9: '9'}
WHITESPACE = {32, 10, 13, 9}
