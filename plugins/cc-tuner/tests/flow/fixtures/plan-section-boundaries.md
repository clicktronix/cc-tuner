**Spec:** docs/PLANS/example.md
**Branch:** feat/example

## Slice 1 — Done
Blocked by: none
Owned paths: src/old/
Deciding check: true
Delivers: Old work

- [X] old work

~~~~markdown
```md
## Slice 99 — Hidden by a different marker
Blocked by: none
Owned paths: src/example/
Deciding check: false
Delivers: Example
- [ ] example
~~~
- [ ] hidden by a shorter marker
~~~~ keep fenced with trailing info
- [ ] hidden by a non-closing marker
~~~~

## Deliver

- [ ] publish release

## Slice 2 — Open
Blocked by: 1
Owned paths: lib/, docs/My File.md, docs/отчёт.md
Deciding check: true
Delivers: Report

### Details

- [ ] publish report

````markdown
~~~
## Slice 100 — Also hidden
```
- [x] hidden by a shorter backtick marker
`````
