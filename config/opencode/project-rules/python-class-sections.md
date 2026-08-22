<!-- Project rule: section header comment style inside Python classes.
     Use by pasting into a project's AGENTS.md or listing this file's path in the project's opencode.json "instructions" array. -->

# Python Class Sections

Applies to Python files.

- When editing or generating Python code, and especially inside Python classes, organize the class body into clearly separated sections: typically **Properties**, **Public methods**, and **Private methods**.

- Never create empty sections (or empty subsections). Only add a section/subsection header if at least one attribute/method will appear under it, and remove any existing section/subsection headers that have no contents. If a class does not have (for example) `Properties` or `Private methods`, omit that header entirely.

- For each *top-level section* inside a class, use a three-line "big" header comment, indented to the class level, with an `=` border **above and below** the label. Use this template, updating only the section name:

    ```python
    class SomeClass:
        # ==================================================================
        # === Properties ===================================================
        # ==================================================================

        ...
    ```

- Use exactly these section labels and capitalization when applicable:
  - `Properties`
  - `Public methods`
  - `Private methods`

  For example:

    ```python
    class SomeClass:
        # ==================================================================
        # === Properties ===================================================
        # ==================================================================
        ...

        # ==================================================================
        # === Public methods ===============================================
        # ==================================================================
        ...

        # ==================================================================
        # === Private methods ==============================================
        # ==================================================================
        ...
    ```

- Always:
  - Indent the big headers to the same level as the methods in the class.
  - Leave **one blank line before** each big header block (except when it's the first thing in the class).
  - Leave **one blank line after** the big header block before the first method in that section.

- For *subsections inside a big section* (e.g., grouping related methods), use a single-line, lighter header at the same indentation level, with a `--` prefix and trailing `-` fill. Use this template, updating only the subsection name:

    ```python
        # -- Lifecycle -----------------------------------------------------
        def submit(self) -> None:
            ...

        # -- Event handlers -----------------------------------------------
        def handle_payment_succeeded(self, event: PaymentEvent) -> None:
            ...
    ```

- Subsection rules:
  - One blank line before each subsection header.
  - No blank line between a subsection header and the first method it describes.
  - Subsection names should be short and descriptive (e.g., `Lifecycle`, `Event handlers`, `Internal helpers`).

- Do **not** introduce any alternative header styles inside Python classes. Use only:
  - The 3-line `=== ... ===` headers with `=` borders for **major sections**.
  - The 1-line `# -- ... --` style for **subsections**.
  - Normal `#` comments for inline explanations within methods.

- When refactoring existing classes, prefer to:
  - Introduce or normalize these section headers to match the pattern above.
  - Group methods under the appropriate `Properties`, `Public methods`, and `Private methods` sections, and add logical subsections where it improves readability.
