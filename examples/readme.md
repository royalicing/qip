## Future Ideas

Validation & Checking:

- Semver validator - check if version string is valid, compare versions
- Regex tester - does this string match this pattern? (simple, no full REPL)
- JSON path validator - is this a valid JSONPath?
- Package name validator - npm/pypi/cargo naming rules
- Domain name validator - proper TLD, length, characters
- Credit card number validator - Luhn algorithm check
- IBAN validator - international bank account numbers
- Phone number formatter - normalize to E.164 or local format

Quick Formatting:

- JSON formatter (pretty print) - paste messy JSON, get it formatted
- SQL formatter - indent/format SQL queries
- Remove BOM - strip byte order mark from files
- Normalize line endings - CRLF → LF or vice versa
- Remove trailing whitespace
- Smart quotes to straight quotes - " " → " "
- Case converters - camelCase ↔ snake_case ↔ kebab-case ↔ PascalCase
- Slug from title - "Hello World!" → "hello-world"

Quick Calculations:

- Timestamp converter - unix timestamp ↔ ISO 8601 ↔ human readable
- Duration parser - "2h 30m" → seconds or other units
- File size formatter - bytes → "1.5 MB"
- Percentage calculator - X is what % of Y?
- Character/byte counter - with UTF-8 vs byte distinction
- Color contrast checker - WCAG contrast ratio for two colors
- Timezone converter - what time is it in X when it's Y in Z?

Data Inspection:

- Detect encoding - is this UTF-8, Latin-1, etc?
- Detect file type - magic bytes check
- JWT decoder - show header/payload without verification
- Detect language - simple language detection from text
- Line ending detector - CRLF or LF?

String Cleanup:

- Strip ANSI codes - remove terminal color codes
- Unescape string - JSON/JavaScript escape sequences to actual characters
- Extract URLs from text
- Extract emails from text
- Remove duplicate lines (preserve order)
- Extract numbers from text

Security/Privacy:

- Redact sensitive data - replace credit cards, emails, IPs with X's
- Password generator - configurable length/charset
- Check if email is disposable - against known disposable domains
- Secret scanner - look for API keys, tokens in text

Developer-Specific:

- Git commit message validator - conventional commits format
- Docker image tag validator
- Kubernetes resource name validator
- AWS ARN parser
- GitHub/GitLab URL parser - extract org/repo/branch
- npm/yarn/pnpm lockfile version extractor

Text/Data Processing:

- JSON extractors - jq-style simple queries (e.g., extract a field by path)
- CSV to JSON / JSON to CSV converters
- XML to JSON (or other format conversions)
- Markdown to HTML (lightweight, no full Markdown spec)
- YAML validator or simple YAML to JSON
- INI file parser

Encoding/Escaping:

- URL encoder/decoder - percent encoding
- HTML entity encoder (we discussed this!)
- Unicode normalizer (NFC, NFD, etc.)
- Punycode encoder/decoder (IDN domains)
- SQL string escaper

Hashing & Crypto:

- MD5, SHA1, SHA256 (you have CRC already)
- HMAC generators
- UUID generator (v4, v5)
- Password strength checker
- bcrypt verifier (check against hash)

Web/Network:

- Email address normalizer (lowercase domain, remove dots from gmail, etc.)
- URL parser (extract parts: scheme, host, path, query)
- IP address validator (v4/v6)
- CIDR calculator
- User-Agent parser

Data Generation:

- Lorem ipsum generator
- Fake data generator (names, emails, etc.)
- Random string generator (for tokens, passwords)

Practical Utilities:

- diff calculator (simple line diff)
- word/line/char counter with stats
- text deduplicator (unique lines)
- sort (various modes)
- template renderer (simple variable substitution)
