# Code Review Comment Examples

Examples of good vs. bad review comments across different scenarios.

## Blocker Comments

### Security Issue

**Bad:**
```
This is insecure.
```

**Good:**
```
blocker: SQL injection vulnerability

User input is concatenated directly into the query:
query = f"SELECT * FROM users WHERE id = {user_id}"

This allows attackers to inject arbitrary SQL. Use parameterized queries:
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))
```

### Bug

**Bad:**
```
This will crash.
```

**Good:**
```
blocker: NullPointerException when user has no orders

At line 45, `user.orders[0]` will throw if the orders list is empty.
Consider adding a guard:

if not user.orders:
    return None
return user.orders[0]
```

### Logic Error

**Bad:**
```
Wrong logic here.
```

**Good:**
```
blocker: Off-by-one error in pagination

The current logic skips the first item on each page:
offset = page * page_size  # When page=0, offset=0 is correct
                           # When page=1, offset=page_size skips item[page_size-1]

Should be:
offset = (page - 1) * page_size  # Assuming 1-indexed pages
```

---

## Suggestion Comments

### Performance Improvement

**Bad:**
```
This is slow.
```

**Good:**
```
suggestion: N+1 query issue

This loop makes a database query for each user, causing N+1 queries:

for user in users:
    orders = db.query(f"SELECT * FROM orders WHERE user_id = {user.id}")

Consider fetching all orders in one query:

user_ids = [u.id for u in users]
all_orders = db.query("SELECT * FROM orders WHERE user_id IN (%s)", user_ids)
orders_by_user = group_by(all_orders, 'user_id')
```

### Code Structure

**Bad:**
```
Too long.
```

**Good:**
```
suggestion: Consider splitting this function

At 80 lines, this function handles validation, transformation, and persistence.
Breaking it into `validate_input()`, `transform_data()`, and `save_record()`
would make each piece easier to test and understand.
```

### Error Handling

**Bad:**
```
Add error handling.
```

**Good:**
```
suggestion: Handle API timeout gracefully

If the external API times out, this will raise an unhandled exception.
Consider:

try:
    response = api_client.fetch(endpoint, timeout=30)
except TimeoutError:
    logger.warning("API timeout, using cached value")
    return self.cache.get(endpoint)
```

### DRY Violation

**Bad:**
```
This is duplicated.
```

**Good:**
```
suggestion: Extract duplicated validation logic

This email validation appears in three places:
- `user_service.py:45`
- `registration_handler.py:78`
- `admin_views.py:112`

Consider extracting to a shared `validate_email()` function. This ensures
consistent behavior and makes future updates easier (e.g., adding new
validation rules only needs one change).
```

### SOLID Violation (Single Responsibility)

**Bad:**
```
This class does too much.
```

**Good:**
```
suggestion: Split OrderProcessor into focused classes

OrderProcessor currently handles validation, payment processing, inventory
updates, and email notifications. This makes it hard to test and modify.

Consider splitting into:
- `OrderValidator` — validates order data
- `PaymentService` — handles payment processing
- `InventoryManager` — updates stock levels
- `OrderNotifier` — sends confirmation emails

Then `OrderProcessor` orchestrates these, each testable in isolation.
```

### SOLID Violation (Dependency Inversion)

**Bad:**
```
Don't hardcode the database.
```

**Good:**
```
suggestion: Inject the database connection instead of creating it internally

Currently the class instantiates its own database connection:

class UserRepository:
    def __init__(self):
        self.db = PostgresConnection("localhost", "mydb")

This makes testing difficult and couples the class to Postgres. Consider:

class UserRepository:
    def __init__(self, db: DatabaseConnection):
        self.db = db

Now tests can inject a mock, and you can swap implementations without
changing this class.
```

---

## Nit Comments

### Naming

**Bad:**
```
Bad name.
```

**Good:**
```
nit: `userList` → `users`

Plural nouns are typically preferred over type suffixes for collections.
```

**Good (vague function name):**
```
suggestion: `process()` → more descriptive name

`process()` doesn't convey what this function does. Based on the implementation,
something like `calculate_shipping_cost()` or `validate_and_transform_order()`
would make the code self-documenting.
```

**Good (cryptic abbreviation):**
```
nit: `usr_mgr` → `user_manager`

The abbreviation saves a few characters but hurts readability. Prefer
full words unless the abbreviation is universally understood (like `id`, `url`).
```

**Good (misleading name):**
```
suggestion: Rename `get_user()` — it also creates users

This function creates a user if one doesn't exist, which is unexpected
from the name. Consider `get_or_create_user()` or splitting into
`get_user()` and `create_user()` with the caller deciding.
```

### Code Style

**Bad:**
```
Format this.
```

**Good:**
```
nit: Inconsistent string quotes

This file mixes single and double quotes. The project uses single quotes
for strings per .editorconfig.
```

### Minor Improvement

**Bad:**
```
Change this.
```

**Good:**
```
nit: Could use list comprehension

This loop:
result = []
for item in items:
    result.append(item.name)

Could be:
result = [item.name for item in items]
```

---

## Question Comments

### Seeking Understanding

**Bad:**
```
Why?
```

**Good:**
```
question: What's the reason for the 5-second delay here?

I see we sleep for 5 seconds before retrying. Is this to rate-limit,
or is there a specific timing requirement from the external service?
```

### Clarifying Intent

**Bad:**
```
Explain this.
```

**Good:**
```
question: Is the empty string check intentional here?

if value == "":
    return default

This only catches empty strings, not None. Should this also handle None,
or is there a reason we treat them differently?
```

### Edge Case Inquiry

**Bad:**
```
What about errors?
```

**Good:**
```
question: What happens if the file doesn't exist?

I see we open the file without checking existence:
with open(config_path) as f:

Should we handle FileNotFoundError with a helpful message, or is it
expected that callers ensure the file exists?
```

---

## Praise Comments

### Acknowledging Good Work

**Bad:**
```
Nice.
```

**Good:**
```
praise: Excellent error handling strategy here

The exponential backoff with jitter is exactly right for avoiding
thundering herd problems. Well thought out!
```

### Recognizing Improvement

**Good:**
```
praise: This refactoring significantly improves readability

Breaking the validation into its own class makes the main flow
much clearer. Future developers will thank you.
```

### Learning From Code

**Good:**
```
praise: I learned something new here!

I didn't know you could use `functools.cached_property` for lazy
initialization. This is cleaner than the manual pattern I usually use.
```

---

## Anti-Pattern Examples

### Personal Attacks (Never Do This)

**Terrible:**
```
Did you even test this?
Why would anyone write it this way?
You clearly don't understand how this works.
```

**Better:**
```
question: Have we had a chance to test the error path here?
I'd like to make sure it handles the failure case correctly.
```

### Vague Criticism (Never Do This)

**Terrible:**
```
This is bad.
Needs work.
I don't like this approach.
```

**Better:**
```
suggestion: Consider using dependency injection here

Creating the database connection inside the function makes it hard to test.
Passing it as a parameter would allow injecting a mock in tests.
```

### Demanding Tone (Never Do This)

**Terrible:**
```
Fix this.
Don't do this.
Use X instead.
```

**Better:**
```
suggestion: What do you think about using X here?

It might handle the edge case at line 45 more elegantly.
```

---

## Comment Grouping

When you have multiple small nits in the same area, group them:

**Good:**
```
nit: A few style items in this file:

- Line 12: `userList` → `users` (prefer plural over type suffix)
- Line 18: Missing trailing comma in dict (helps with future diffs)
- Line 25: Consider `is None` instead of `== None`

None of these are blocking, just polish.
```

---

## Review Summary Examples

### Approve with Comments

```markdown
## Review Summary

**Overall**: Approve

This is a solid implementation of the caching layer. A few minor
suggestions below, but nothing blocking.

### Suggestions
- Consider adding TTL configuration (see comment on line 45)
- The retry logic could use exponential backoff

### Nits
- A few naming consistency items

### What's Good
- Clean separation of concerns
- Excellent test coverage
- Good error messages
```

### Request Changes

```markdown
## Review Summary

**Overall**: Request Changes

Found a security issue that needs to be addressed before merge.
The rest looks good.

### Blockers (must fix)
- SQL injection vulnerability in user lookup (line 78)

### Suggestions
- Add input validation for email format
- Consider rate limiting on this endpoint

### What's Good
- Good API design
- Comprehensive logging
```
