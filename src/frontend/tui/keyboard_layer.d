module neme.frontend.tui.keyboard_layer;

import nice.ui.elements: WChar;

enum Operations
{
    CHAR_LEFT,
    CHAR_RIGHT,
    LINE_UP,
    LINE_DOWN,
    PAGE_UP,
    PAGE_DOWN,
    LOAD_FILE,
    QUIT,
    UNKNOWN,
}

// Interface defining the key commands that keyboard layers must 
// implement. Every command returns one or more WChars matching the
// nice-curses codes for the keys that implement the command, as returned by 
// src.getwch
interface KeyboardLayer
{
    // FIXME: const or immutable
    Operations getOpForKey(WChar key);
}