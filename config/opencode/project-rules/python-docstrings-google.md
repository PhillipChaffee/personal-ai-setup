<!-- Project rule: Google-style Python docstrings.
     Use by pasting into a project's AGENTS.md or listing this file's path in the project's opencode.json "instructions" array. -->

# Python Docstrings (Google Style)

Applies to Python files.

- Follow the Google Python Style Guide for all Python docstrings, using **Google-style**
  sections (see `https://google.github.io/styleguide/pyguide.html#38-comments-and-docstrings`).

- **General rules**
  - Use triple double quotes (`"""`) for all docstrings (modules, classes, functions, methods).
  - Start with a one-line summary in the imperative mood (e.g., "Return X", "Compute Y").
  - Add a blank line after the summary before any extended description or sections.
  - Keep lines to 100 characters or fewer, consistent with the project rules.

- **Function and method docstrings**
  - Use these section headers when relevant, in this order:
    - `Args:`
    - `Returns:` or `Yields:`
    - `Raises:`
  - Indent section contents by 4 spaces, one parameter/return/raise entry per line.
  - Do **not** repeat type information in the docstring when it is already in type hints;
    focus on meaning and behavior instead.

  - **Example (synchronous function)**:

    ```python
    def compute_score(value: int, *, weight: float = 1.0) -> float:
        """Compute a weighted score from the input value.

        Args:
            value: The base integer value to score.
            weight: Multiplier applied to the base value.

        Returns:
            The weighted score as a float.

        Raises:
            ValueError: If weight is negative.
        """
    ```

  - **Example (async function)**:

    ```python
    async def fetch_user(user_id: int) -> dict[str, str]:
        """Fetch user data from the remote service.

        Args:
            user_id: Identifier of the user to fetch.

        Returns:
            A mapping of user fields returned by the service.
        """
    ```

- **Class docstrings**
  - Provide a high-level description of the class responsibility.
  - When documenting instance attributes, use an `Attributes:` section:

    ```python
    class UserSession:
        """Track state for a single user session.

        Attributes:
            user_id: Identifier of the active user.
            expires_at: Epoch timestamp when the session expires.
        """
    ```

- **Other guidance**
  - Prefer clear, concise language over repeating implementation details.
  - For very simple functions where the name already fully describes behavior, a short
    one-line summary without sections is acceptable.
