#include <stdio.h>
#include <stdlib.h>

/*
 * Workflow
 * 1. [ ] Get list of files to process filtering out according to rules
 * 2. [ ] Process backlinks, tables of content
 * 3. [ ] For each file:
 * 3.1. [ ] Split Frontmatter and Markdown
 * 3.2. [ ] Add/modify links
 * 3.3. [ ] Process content according to rules, add HTML, inject ToC and backlinks
 * 3.4. [ ] Write output to HTML files
 * 4. [ ] Collect external assets such as images, JS and CSS and bundle/copy them
 */

int main() {
  printf("Hello, World!\n");
  return 0;
}
