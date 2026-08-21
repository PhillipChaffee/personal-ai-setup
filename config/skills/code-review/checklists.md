# Code Review Checklists

Comprehensive checklists for systematic code review across five dimensions.

## 1. Security Checklist

### Input Validation & Injection Prevention
- [ ] All user inputs validated on server side
- [ ] SQL queries use parameterized queries/prepared statements
- [ ] NoSQL queries properly sanitized
- [ ] Command-line arguments sanitized before shell execution
- [ ] File paths validated to prevent path traversal (`../`)
- [ ] XML parsers disable external entity processing (XXE)
- [ ] Regular expressions not vulnerable to ReDoS
- [ ] LDAP queries use proper escaping

### Authentication & Authorization
- [ ] Authentication required for protected endpoints
- [ ] Authorization checks for every sensitive operation
- [ ] Role-based access control properly implemented
- [ ] Session tokens cryptographically random and long enough
- [ ] Passwords hashed with bcrypt/Argon2/scrypt
- [ ] Password reset tokens expire appropriately
- [ ] Failed logins are rate-limited
- [ ] Session invalidation on logout and password change

### Data Protection
- [ ] Sensitive data not logged (passwords, tokens, PII)
- [ ] API responses don't expose internal details
- [ ] Error messages don't reveal sensitive information
- [ ] Sensitive data encrypted at rest
- [ ] TLS enforced for data in transit
- [ ] Database credentials not hardcoded
- [ ] API keys stored securely (env vars, secrets manager)
- [ ] `.gitignore` excludes sensitive files
- [ ] Debug endpoints disabled in production

### XSS & CSRF
- [ ] User content properly escaped before rendering
- [ ] Content Security Policy headers configured
- [ ] CSRF tokens validated on state-changing requests
- [ ] Cookies have HttpOnly, Secure, SameSite flags
- [ ] DOM manipulation uses safe methods

### Cryptography
- [ ] Modern encryption algorithms (no MD5/SHA1 for security)
- [ ] Cryptographically secure random number generation
- [ ] Encryption keys of sufficient length
- [ ] No custom crypto implementations
- [ ] IV/nonce values never reused

### Dependencies
- [ ] Dependencies from trusted sources
- [ ] No known vulnerable versions
- [ ] Lock files committed
- [ ] Minimal dependency principle followed

---

## 2. Performance Checklist

### Algorithm & Complexity
- [ ] Time complexity appropriate for data size
- [ ] Nested loops necessary and bounded
- [ ] Recursive functions have proper base cases
- [ ] No O(n²) where O(n log n) exists
- [ ] Early termination used where applicable

### Memory Management
- [ ] Large objects not unnecessarily duplicated
- [ ] Generators used for large data streams
- [ ] Resources properly closed (files, connections)
- [ ] Context managers used where appropriate
- [ ] No memory leaks from circular references
- [ ] Large collections paginated

### Database & Queries
- [ ] N+1 query problems avoided
- [ ] Queries have appropriate indexes
- [ ] `SELECT *` avoided when specific columns suffice
- [ ] Bulk operations used instead of individual ops
- [ ] Database connections pooled
- [ ] Transactions scoped appropriately
- [ ] Query results limited

### Caching
- [ ] Expensive operations cached
- [ ] Cache invalidation strategy defined
- [ ] Cache keys unique and collision-free
- [ ] TTL values appropriate
- [ ] Cache stampede prevented
- [ ] Memoization for pure functions

### Async & Concurrency
- [ ] No blocking in async contexts
- [ ] I/O-bound operations use async
- [ ] Thread safety for shared resources
- [ ] Connection pools appropriately sized
- [ ] Timeouts set for external calls
- [ ] Parallel execution for independent operations

### Network & I/O
- [ ] HTTP keep-alive connections reused
- [ ] Compression enabled for large payloads
- [ ] Batch API calls instead of individual
- [ ] Response payload size minimized
- [ ] Lazy loading where beneficial

---

## 3. Code Quality Checklist

### Naming
- [ ] Variable names descriptive and purposeful
- [ ] Function names describe action
- [ ] Booleans use is/has/can/should prefixes
- [ ] Abbreviations avoided unless standard
- [ ] Naming follows language conventions
- [ ] Constants in UPPER_SNAKE_CASE
- [ ] Classes in PascalCase and noun-based
- [ ] No single-letter variables (except short lambdas/loops)

### Structure
- [ ] Functions focused, do one thing
- [ ] Function length reasonable (<30 lines guideline)
- [ ] Nesting depth limited (≤3 levels)
- [ ] Related code grouped together
- [ ] Imports organized and sorted
- [ ] Dead code removed
- [ ] Magic numbers replaced with constants
- [ ] Consistent formatting

### DRY
- [ ] Duplicated logic extracted to shared functions
- [ ] Copy-pasted code refactored
- [ ] Configuration values centralized
- [ ] Common patterns use helpers/decorators
- [ ] Similar classes share base or composition

### SOLID Principles

**Single Responsibility (SRP)**
- [ ] Each class has one reason to change
- [ ] Functions perform single task
- [ ] Modules have focused purposes

**Open/Closed (OCP)**
- [ ] Open for extension, closed for modification
- [ ] New features without changing existing code
- [ ] Strategy/plugin patterns where appropriate

**Liskov Substitution (LSP)**
- [ ] Subclasses substitute parents without issues
- [ ] Derived classes don't throw unexpected exceptions
- [ ] Consistent method signatures across hierarchy

**Interface Segregation (ISP)**
- [ ] Interfaces small and focused
- [ ] Classes don't implement unused methods
- [ ] Large interfaces split

**Dependency Inversion (DIP)**
- [ ] High-level modules don't depend on low-level
- [ ] Dependencies injected, not created internally
- [ ] Abstractions over concrete implementations

### Error Handling
- [ ] Exceptions caught at appropriate levels
- [ ] Specific exceptions caught, not bare except
- [ ] Error messages informative and actionable
- [ ] Errors logged with context
- [ ] Fail-fast for unrecoverable errors
- [ ] Graceful degradation for recoverable

### Readability
- [ ] Complex logic has explanatory comments
- [ ] Code understandable without running
- [ ] Straightforward control flow
- [ ] Early returns reduce nesting
- [ ] Guard clauses for edge cases

---

## 4. Testing Checklist

### Coverage
- [ ] New code has corresponding tests
- [ ] Critical paths covered
- [ ] Public API methods tested
- [ ] Both if/else branches covered
- [ ] Error handling paths tested
- [ ] Integration points have integration tests

### Edge Cases
- [ ] Empty inputs tested
- [ ] Boundary values tested (0, -1, max)
- [ ] Invalid inputs tested
- [ ] Unicode and special characters tested
- [ ] Large inputs tested
- [ ] Concurrent access tested

### Test Quality
- [ ] Tests independent, any order
- [ ] Tests deterministic (no flaky)
- [ ] Test names describe what's tested
- [ ] Arrange-Act-Assert pattern
- [ ] Each test tests one thing
- [ ] Tests don't test implementation details

### Mocking & Isolation
- [ ] External services mocked in unit tests
- [ ] Database mocked or uses test DB
- [ ] Time-dependent code uses injectable clock
- [ ] Random uses seeded generators
- [ ] File system isolated
- [ ] Mocks fail on unexpected calls

### Test Data
- [ ] Realistic but not production data
- [ ] Fixtures for complex setup
- [ ] Test data cleaned up
- [ ] Parameterized for multiple scenarios
- [ ] Factory patterns for test objects

---

## 5. Documentation Checklist

### Code Comments
- [ ] Complex algorithms explained
- [ ] Non-obvious business logic documented
- [ ] Comments explain "why", not "what"
- [ ] TODOs include context and tracking
- [ ] Outdated comments updated/removed
- [ ] Commented-out code removed
- [ ] External reference links included

### Docstrings & API Docs
- [ ] Public functions have docstrings
- [ ] Docstrings follow project convention
- [ ] Parameters documented with types
- [ ] Return values documented
- [ ] Exceptions documented
- [ ] Usage examples for complex functions
- [ ] Deprecated functions marked

### Type Annotations
- [ ] Function signatures have type hints
- [ ] Return types specified
- [ ] Complex types use aliases
- [ ] Optional parameters annotated
- [ ] Generics used appropriately

### Project Docs
- [ ] README updated for new features
- [ ] Installation instructions current
- [ ] Configuration options documented
- [ ] API endpoints documented
- [ ] Changelog updated

---

## Priority Guide

When reviewing, prioritize in this order:

1. **P0 (Blocker)**: Security vulnerabilities, data loss risks, breaking changes
2. **P1 (High)**: Bugs, performance regressions, missing critical tests
3. **P2 (Medium)**: Code quality issues, minor test gaps
4. **P3 (Low)**: Documentation, style suggestions
