# Word Search Puzzle Plugin for KOReader

This KOReader plugin generates classic word search puzzles directly on your device. Each puzzle mixes horizontal, vertical, and diagonal words while heuristics spread words across directions and starting points to avoid clustering.

## Gameplay overview
1. Launch **Tools → Word Search**.
2. Tap the first and last letters of a word to select it. A line is drawn behind the grid letters and highlighted when the match is correct.
3. Tap **Words** to view the current list (found words are struck through).
4. Use **Show solution / Hide solution** to toggle helper lines for every hidden word.
5. A congratulatory overlay appears once every word is found.

## Adjustable settings
All settings persist between sessions.

- **Word count**: Choose 6–24 words per puzzle. Changing the count regenerates the grid.
- **Grid size**: Pick an 8×8 up to 16×16 board. The plugin automatically validates sizes and regenerates the puzzle.
- **Grid zoom**: Switch between predefined zoom levels that control the rendered cell size.
- **Word lists**: Select from bundled lists or any compatible `.txt` file to refresh the board with new vocabulary.
- **New puzzle**: Forces immediate regeneration with the current settings.

## Word lists
Bundled lists live under `wordsearch.koplugin/word_lists`. Each list is a UTF‑8 text file with optional metadata on the first line, then one word per line, for example:

```
lang=en letters=ABCDEFGHIJKLMNOPQRSTUVWXYZ title=English_Basics_2k
abolish
abortion
...
```

- `lang` identifies the language tag displayed in the UI.
- `letters` restricts which characters the board may use when filling unused cells.
- `title` is shown in menus and the Words overlay.

Add your own `.txt` files to this folder (or point the plugin to any accessible file). After selecting a new list, the plugin stores the path and reloads with the updated words.

## Saving & continuity
The plugin saves the active board, chosen list, grid size, max word count, and zoom level to KOReader's settings directory. Closing and reopening KOReader resumes exactly where you left off unless you generate a new puzzle.

## Credits
Created with the help of Windsurf (AI).
