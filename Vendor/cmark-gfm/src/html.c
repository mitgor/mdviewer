#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "cmark_ctype.h"
#include "cmark-gfm_config.h"
#include "cmark-gfm.h"
#include "houdini.h"
#include "scanners.h"
#include "syntax_extension.h"
#include "html.h"
#include "render.h"
#include "iterator.h"

// Functions to convert cmark_nodes to HTML strings.

static const struct { const char *s; int len; } S_heading_open[] = {
  {NULL, 0}, {"<h1", 3}, {"<h2", 3}, {"<h3", 3}, {"<h4", 3}, {"<h5", 3}, {"<h6", 3}
};
static const struct { const char *s; int len; } S_heading_close[] = {
  {NULL, 0}, {"</h1>\n", 6}, {"</h2>\n", 6}, {"</h3>\n", 6},
  {"</h4>\n", 6}, {"</h5>\n", 6}, {"</h6>\n", 6}
};

static void escape_html(cmark_strbuf *dest, const unsigned char *source,
                        bufsize_t length) {
  houdini_escape_html0(dest, source, length, 0);
}

static void filter_html_block(cmark_html_renderer *renderer, uint8_t *data, size_t len) {
  cmark_strbuf *html = renderer->html;
  cmark_llist *it;
  cmark_syntax_extension *ext;
  bool filtered;
  uint8_t *match;

  if (!renderer->has_filter_extensions) {
    cmark_strbuf_put(html, data, (bufsize_t)len);
    return;
  }

  while (len) {
    match = (uint8_t *) memchr(data, '<', len);
    if (!match)
      break;

    if (match != data) {
      cmark_strbuf_put(html, data, (bufsize_t)(match - data));
      len -= (match - data);
      data = match;
    }

    filtered = false;
    for (it = renderer->filter_extensions; it; it = it->next) {
      ext = ((cmark_syntax_extension *) it->data);
      if (!ext->html_filter_func(ext, data, len)) {
        filtered = true;
        break;
      }
    }

    if (!filtered) {
      cmark_strbuf_putc(html, '<');
    } else {
      cmark_strbuf_puts_lit(html, "&lt;");
    }

    ++data;
    --len;
  }

  if (len)
    cmark_strbuf_put(html, data, (bufsize_t)len);
}

static bool S_put_footnote_backref(cmark_html_renderer *renderer, cmark_strbuf *html, cmark_node *node) {
  if (renderer->written_footnote_ix >= renderer->footnote_ix)
    return false;
  renderer->written_footnote_ix = renderer->footnote_ix;
  char m[16];
  int m_len = cmark_itoa(m, renderer->written_footnote_ix);

  cmark_strbuf_puts_lit(html, "<a href=\"#fnref-");
  houdini_escape_href(html, node->as.literal.data, node->as.literal.len);
  cmark_strbuf_puts_lit(html, "\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"");
  cmark_strbuf_put(html, (const unsigned char *)m, m_len);
  cmark_strbuf_puts_lit(html, "\" aria-label=\"Back to reference ");
  cmark_strbuf_put(html, (const unsigned char *)m, m_len);
  cmark_strbuf_puts_lit(html, "\">↩</a>");

  if (node->footnote.def_count > 1)
  {
    for(int i = 2; i <= node->footnote.def_count; i++) {
      char n[16];
      int n_len = cmark_itoa(n, i);

      cmark_strbuf_puts_lit(html, " <a href=\"#fnref-");
      houdini_escape_href(html, node->as.literal.data, node->as.literal.len);
      cmark_strbuf_puts_lit(html, "-");
      cmark_strbuf_put(html, (const unsigned char *)n, n_len);
      cmark_strbuf_puts_lit(html, "\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"");
      cmark_strbuf_put(html, (const unsigned char *)m, m_len);
      cmark_strbuf_puts_lit(html, "-");
      cmark_strbuf_put(html, (const unsigned char *)n, n_len);
      cmark_strbuf_puts_lit(html, "\" aria-label=\"Back to reference ");
      cmark_strbuf_put(html, (const unsigned char *)m, m_len);
      cmark_strbuf_puts_lit(html, "-");
      cmark_strbuf_put(html, (const unsigned char *)n, n_len);
      cmark_strbuf_puts_lit(html, "\">↩<sup class=\"footnote-ref\">");
      cmark_strbuf_put(html, (const unsigned char *)n, n_len);
      cmark_strbuf_puts_lit(html, "</sup></a>");
    }
  }

  return true;
}

static int S_render_node(cmark_html_renderer *renderer, cmark_node *node,
                         cmark_event_type ev_type, int options) {
  cmark_node *parent;
  cmark_node *grandparent;
  cmark_strbuf *html = renderer->html;
  cmark_llist *it;
  cmark_syntax_extension *ext;
  bool tight;
  bool filtered;

  bool entering = (ev_type == CMARK_EVENT_ENTER);

  if (renderer->plain == node) { // back at original node
    renderer->plain = NULL;
  }

  if (renderer->plain != NULL) {
    switch (node->type) {
    case CMARK_NODE_TEXT:
    case CMARK_NODE_CODE:
    case CMARK_NODE_HTML_INLINE:
      escape_html(html, node->as.literal.data, node->as.literal.len);
      break;

    case CMARK_NODE_LINEBREAK:
    case CMARK_NODE_SOFTBREAK:
      cmark_strbuf_putc(html, ' ');
      break;

    default:
      break;
    }
    return 1;
  }

  if (node->extension && node->extension->html_render_func) {
    node->extension->html_render_func(node->extension, renderer, node, ev_type, options);
    return 1;
  }

  switch (node->type) {
  case CMARK_NODE_DOCUMENT:
    break;

  case CMARK_NODE_BLOCK_QUOTE:
    if (entering) {
      cmark_html_render_cr(html);
      cmark_strbuf_puts_lit(html, "<blockquote");
      cmark_html_render_sourcepos(node, html, options);
      cmark_strbuf_puts_lit(html, ">\n");
    } else {
      cmark_html_render_cr(html);
      cmark_strbuf_puts_lit(html, "</blockquote>\n");
    }
    break;

  case CMARK_NODE_LIST: {
    cmark_list_type list_type = node->as.list.list_type;
    int start = node->as.list.start;

    if (entering) {
      cmark_html_render_cr(html);
      if (list_type == CMARK_BULLET_LIST) {
        cmark_strbuf_puts_lit(html, "<ul");
        cmark_html_render_sourcepos(node, html, options);
        cmark_strbuf_puts_lit(html, ">\n");
      } else if (start == 1) {
        cmark_strbuf_puts_lit(html, "<ol");
        cmark_html_render_sourcepos(node, html, options);
        cmark_strbuf_puts_lit(html, ">\n");
      } else {
        cmark_strbuf_puts_lit(html, "<ol start=\"");
        {
          char n[16];
          int n_len = cmark_itoa(n, start);
          cmark_strbuf_put(html, (const unsigned char *)n, n_len);
        }
        cmark_strbuf_putc(html, '"');
        cmark_html_render_sourcepos(node, html, options);
        cmark_strbuf_puts_lit(html, ">\n");
      }
    } else {
      cmark_strbuf_puts(html,
                        list_type == CMARK_BULLET_LIST ? "</ul>\n" : "</ol>\n");
    }
    break;
  }

  case CMARK_NODE_ITEM:
    if (entering) {
      cmark_html_render_cr(html);
      cmark_strbuf_puts_lit(html, "<li");
      cmark_html_render_sourcepos(node, html, options);
      cmark_strbuf_putc(html, '>');
    } else {
      cmark_strbuf_puts_lit(html, "</li>\n");
    }
    break;

  case CMARK_NODE_HEADING: {
    int level = node->as.heading.level;
    if (entering) {
      cmark_html_render_cr(html);
      cmark_strbuf_put(html, (const unsigned char *)S_heading_open[level].s,
                       S_heading_open[level].len);
      cmark_html_render_sourcepos(node, html, options);
      cmark_strbuf_putc(html, '>');
    } else {
      cmark_strbuf_put(html, (const unsigned char *)S_heading_close[level].s,
                       S_heading_close[level].len);
    }
    break;
  }

  case CMARK_NODE_CODE_BLOCK:
    cmark_html_render_cr(html);

    if (node->as.code.info.len == 0) {
      cmark_strbuf_puts_lit(html, "<pre");
      cmark_html_render_sourcepos(node, html, options);
      cmark_strbuf_puts_lit(html, "><code>");
    } else {
      bufsize_t first_tag = 0;
      while (first_tag < node->as.code.info.len &&
             !cmark_isspace(node->as.code.info.data[first_tag])) {
        first_tag += 1;
      }

      if (options & CMARK_OPT_GITHUB_PRE_LANG) {
        cmark_strbuf_puts_lit(html, "<pre");
        cmark_html_render_sourcepos(node, html, options);
        cmark_strbuf_puts_lit(html, " lang=\"");
        escape_html(html, node->as.code.info.data, first_tag);
        if (first_tag < node->as.code.info.len && (options & CMARK_OPT_FULL_INFO_STRING)) {
          cmark_strbuf_puts_lit(html, "\" data-meta=\"");
          escape_html(html, node->as.code.info.data + first_tag + 1, node->as.code.info.len - first_tag - 1);
        }
        cmark_strbuf_puts_lit(html, "\"><code>");
      } else {
        cmark_strbuf_puts_lit(html, "<pre");
        cmark_html_render_sourcepos(node, html, options);
        cmark_strbuf_puts_lit(html, "><code class=\"language-");
        escape_html(html, node->as.code.info.data, first_tag);
        if (first_tag < node->as.code.info.len && (options & CMARK_OPT_FULL_INFO_STRING)) {
          cmark_strbuf_puts_lit(html, "\" data-meta=\"");
          escape_html(html, node->as.code.info.data + first_tag + 1, node->as.code.info.len - first_tag - 1);
        }
        cmark_strbuf_puts_lit(html, "\">");
      }
    }

    escape_html(html, node->as.code.literal.data, node->as.code.literal.len);
    cmark_strbuf_puts_lit(html, "</code></pre>\n");
    break;

  case CMARK_NODE_HTML_BLOCK:
    cmark_html_render_cr(html);
    if (!(options & CMARK_OPT_UNSAFE)) {
      cmark_strbuf_puts_lit(html, "<!-- raw HTML omitted -->");
    } else if (renderer->filter_extensions) {
      filter_html_block(renderer, node->as.literal.data, node->as.literal.len);
    } else {
      cmark_strbuf_put(html, node->as.literal.data, node->as.literal.len);
    }
    cmark_html_render_cr(html);
    break;

  case CMARK_NODE_CUSTOM_BLOCK:
    cmark_html_render_cr(html);
    if (entering) {
      cmark_strbuf_put(html, node->as.custom.on_enter.data,
                       node->as.custom.on_enter.len);
    } else {
      cmark_strbuf_put(html, node->as.custom.on_exit.data,
                       node->as.custom.on_exit.len);
    }
    cmark_html_render_cr(html);
    break;

  case CMARK_NODE_THEMATIC_BREAK:
    cmark_html_render_cr(html);
    cmark_strbuf_puts_lit(html, "<hr");
    cmark_html_render_sourcepos(node, html, options);
    cmark_strbuf_puts_lit(html, " />\n");
    break;

  case CMARK_NODE_PARAGRAPH:
    parent = cmark_node_parent(node);
    grandparent = cmark_node_parent(parent);
    if (grandparent != NULL && grandparent->type == CMARK_NODE_LIST) {
      tight = grandparent->as.list.tight;
    } else {
      tight = false;
    }
    if (!tight) {
      if (entering) {
        cmark_html_render_cr(html);
        cmark_strbuf_puts_lit(html, "<p");
        cmark_html_render_sourcepos(node, html, options);
        cmark_strbuf_putc(html, '>');
      } else {
        if (parent->type == CMARK_NODE_FOOTNOTE_DEFINITION && node->next == NULL) {
          cmark_strbuf_putc(html, ' ');
          S_put_footnote_backref(renderer, html, parent);
        }
        cmark_strbuf_puts_lit(html, "</p>\n");
      }
    }
    break;

  case CMARK_NODE_TEXT:
    escape_html(html, node->as.literal.data, node->as.literal.len);
    break;

  case CMARK_NODE_LINEBREAK:
    cmark_strbuf_puts_lit(html, "<br />\n");
    break;

  case CMARK_NODE_SOFTBREAK:
    if (options & CMARK_OPT_HARDBREAKS) {
      cmark_strbuf_puts_lit(html, "<br />\n");
    } else if (options & CMARK_OPT_NOBREAKS) {
      cmark_strbuf_putc(html, ' ');
    } else {
      cmark_strbuf_putc(html, '\n');
    }
    break;

  case CMARK_NODE_CODE:
    cmark_strbuf_puts_lit(html, "<code>");
    escape_html(html, node->as.literal.data, node->as.literal.len);
    cmark_strbuf_puts_lit(html, "</code>");
    break;

  case CMARK_NODE_HTML_INLINE:
    if (!(options & CMARK_OPT_UNSAFE)) {
      cmark_strbuf_puts_lit(html, "<!-- raw HTML omitted -->");
    } else if (!renderer->has_filter_extensions) {
      cmark_strbuf_put(html, node->as.literal.data, node->as.literal.len);
    } else {
      filtered = false;
      for (it = renderer->filter_extensions; it; it = it->next) {
        ext = (cmark_syntax_extension *) it->data;
        if (!ext->html_filter_func(ext, node->as.literal.data, node->as.literal.len)) {
          filtered = true;
          break;
        }
      }
      if (!filtered) {
        cmark_strbuf_put(html, node->as.literal.data, node->as.literal.len);
      } else {
        cmark_strbuf_puts_lit(html, "&lt;");
        cmark_strbuf_put(html, node->as.literal.data + 1, node->as.literal.len - 1);
      }
    }
    break;

  case CMARK_NODE_CUSTOM_INLINE:
    if (entering) {
      cmark_strbuf_put(html, node->as.custom.on_enter.data,
                       node->as.custom.on_enter.len);
    } else {
      cmark_strbuf_put(html, node->as.custom.on_exit.data,
                       node->as.custom.on_exit.len);
    }
    break;

  case CMARK_NODE_STRONG:
    if (node->parent == NULL || node->parent->type != CMARK_NODE_STRONG) {
      if (entering) {
        cmark_strbuf_puts_lit(html, "<strong>");
      } else {
        cmark_strbuf_puts_lit(html, "</strong>");
      }
    }
    break;

  case CMARK_NODE_EMPH:
    if (entering) {
      cmark_strbuf_puts_lit(html, "<em>");
    } else {
      cmark_strbuf_puts_lit(html, "</em>");
    }
    break;

  case CMARK_NODE_LINK:
    if (entering) {
      cmark_strbuf_puts_lit(html, "<a href=\"");
      if ((options & CMARK_OPT_UNSAFE) ||
            !(scan_dangerous_url(&node->as.link.url, 0))) {
        houdini_escape_href(html, node->as.link.url.data,
                            node->as.link.url.len);
      }
      if (node->as.link.title.len) {
        cmark_strbuf_puts_lit(html, "\" title=\"");
        escape_html(html, node->as.link.title.data, node->as.link.title.len);
      }
      cmark_strbuf_puts_lit(html, "\">");
    } else {
      cmark_strbuf_puts_lit(html, "</a>");
    }
    break;

  case CMARK_NODE_IMAGE:
    if (entering) {
      cmark_strbuf_puts_lit(html, "<img src=\"");
      if ((options & CMARK_OPT_UNSAFE) ||
            !(scan_dangerous_url(&node->as.link.url, 0))) {
        houdini_escape_href(html, node->as.link.url.data,
                            node->as.link.url.len);
      }
      cmark_strbuf_puts_lit(html, "\" alt=\"");
      renderer->plain = node;
    } else {
      if (node->as.link.title.len) {
        cmark_strbuf_puts_lit(html, "\" title=\"");
        escape_html(html, node->as.link.title.data, node->as.link.title.len);
      }

      cmark_strbuf_puts_lit(html, "\" />");
    }
    break;

  case CMARK_NODE_ATTRIBUTE:
    // TODO: Output span, attributes potentially controlling class/id here. For now just output the main string.
    /*
    if (entering) {
      cmark_strbuf_puts_lit(html, "<span __attributes=\"");
      cmark_strbuf_put(html, node->as.attribute.attributes.data, node->as.attribute.attributes.len);
      cmark_strbuf_puts_lit(html, "\">");
    } else {
      cmark_strbuf_puts_lit(html, "</span>");
    }
    */
    break;

  case CMARK_NODE_FOOTNOTE_DEFINITION:
    if (entering) {
      if (renderer->footnote_ix == 0) {
        cmark_strbuf_puts_lit(html, "<section class=\"footnotes\" data-footnotes>\n<ol>\n");
      }
      ++renderer->footnote_ix;

      cmark_strbuf_puts_lit(html, "<li id=\"fn-");
      houdini_escape_href(html, node->as.literal.data, node->as.literal.len);
      cmark_strbuf_puts_lit(html, "\">\n");
    } else {
      if (S_put_footnote_backref(renderer, html, node)) {
        cmark_strbuf_putc(html, '\n');
      }
      cmark_strbuf_puts_lit(html, "</li>\n");
    }
    break;

  case CMARK_NODE_FOOTNOTE_REFERENCE:
    if (entering) {
      cmark_strbuf_puts_lit(html, "<sup class=\"footnote-ref\"><a href=\"#fn-");
      houdini_escape_href(html, node->parent_footnote_def->as.literal.data, node->parent_footnote_def->as.literal.len);
      cmark_strbuf_puts_lit(html, "\" id=\"fnref-");
      houdini_escape_href(html, node->parent_footnote_def->as.literal.data, node->parent_footnote_def->as.literal.len);

      if (node->footnote.ref_ix > 1) {
        char n[16];
        int n_len = cmark_itoa(n, node->footnote.ref_ix);
        cmark_strbuf_puts_lit(html, "-");
        cmark_strbuf_put(html, (const unsigned char *)n, n_len);
      }

      cmark_strbuf_puts_lit(html, "\" data-footnote-ref>");
      houdini_escape_href(html, node->as.literal.data, node->as.literal.len);
      cmark_strbuf_puts_lit(html, "</a></sup>");
    }
    break;

  default:
    assert(false);
    break;
  }

  return 1;
}

char *cmark_render_html(cmark_node *root, int options, cmark_llist *extensions) {
  return cmark_render_html_with_mem(root, options, extensions, cmark_node_mem(root));
}

char *cmark_render_html_with_mem(cmark_node *root, int options, cmark_llist *extensions, cmark_mem *mem) {
  char *result;
  cmark_strbuf html = CMARK_BUF_INIT(mem);
  cmark_strbuf_grow(&html, 8192);
  cmark_event_type ev_type;
  cmark_node *cur;
  cmark_html_renderer renderer = {&html, NULL, NULL, 0, 0, NULL, false, true};
  cmark_iter *iter = cmark_iter_new(root);

  for (; extensions; extensions = extensions->next)
    if (((cmark_syntax_extension *) extensions->data)->html_filter_func)
      renderer.filter_extensions = cmark_llist_append(
          mem,
          renderer.filter_extensions,
          (cmark_syntax_extension *) extensions->data);

  renderer.has_filter_extensions = (renderer.filter_extensions != NULL);

  while ((ev_type = cmark_iter_next_inline(iter)) != CMARK_EVENT_DONE) {
    cur = cmark_iter_get_node_inline(iter);
    S_render_node(&renderer, cur, ev_type, options);
  }

  if (renderer.footnote_ix) {
    cmark_strbuf_puts_lit(&html, "</ol>\n</section>\n");
  }

  result = (char *)cmark_strbuf_detach(&html);

  cmark_llist_free(mem, renderer.filter_extensions);

  cmark_iter_free(iter);
  return result;
}
