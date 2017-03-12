module neme;

import gapbuffer;
import std.stdio;

void main()
{
    auto text = "Lorem ipsum blabla";
    auto gBuffer = GapBuffer(text);

    writeln("\n\n=== Start ===");
    gBuffer.debugContent();

    writeln("\n=== Cursor forward 4 ===");
    gBuffer.cursorForward(4);
    gBuffer.debugContent();

    writeln("\n=== Cursor backward 2 ===");
    gBuffer.cursorBackward(2);
    gBuffer.debugContent();

    writeln("=== Cursor backward 1000 ===");
    gBuffer.cursorBackward(10_000);
    gBuffer.debugContent();

    writeln("\n=== Cursor forward 6 ===");
    gBuffer.cursorForward(6);
    gBuffer.debugContent();

    writeln("\n=== Cursor forward 1000 ===");
    gBuffer.cursorForward(10_000);
    gBuffer.debugContent();

    writeln("\n=== Cursor backward 8 ===");
    gBuffer.cursorBackward(8);
    gBuffer.debugContent();

    writeln("\n=== Delete 3 chars to the left (backspace) ===");
    gBuffer.deleteLeft(3);
    gBuffer.debugContent();

    writeln("\n=== Delete 3 chars  to the right (del) ===");
    gBuffer.deleteRight(3);
    gBuffer.debugContent();

    // gBuffer.deleteLeft(10_000);
    // gBuffer.debugContent();

    // gBuffer.deleteRight(10_000);
    // gBuffer.debugContent();
    // gBuffer.deleteRight(10_000);
    // gBuffer.debugContent();

    // gBuffer.deleteLeft(10_000);
    // gBuffer.debugContent();

    writeln("\n=== Reallocate with same sized gap without new text ===");
    // This wont produce a real gap increase since currentGap > original gap size
    gBuffer.reallocate();
    gBuffer.debugContent();

    writeln("\n=== Reallocate with +20 size without new text ===");
    gBuffer.reallocate(20);
    gBuffer.debugContent();

    writeln("\n=== Reallocate with same sized gap with new text ===");
    gBuffer.reallocate("THIS IS THE NEW TEXT");
    gBuffer.debugContent();

    writeln("\n=== Reallocate with +20 sized gap with new text ===");
    gBuffer.reallocate(20, "MORE NEW TEXT");
    gBuffer.debugContent();
}