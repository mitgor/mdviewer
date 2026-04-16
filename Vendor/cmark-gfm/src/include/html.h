#ifndef CMARK_HTML_H
#define CMARK_HTML_H

#include "buffer.h"
#include "node.h"

inline
static void cmark_html_render_cr(cmark_strbuf *html) {
  if (html->size && html->ptr[html->size - 1] != '\n')
    cmark_strbuf_putc(html, '\n');
}

inline
static void cmark_html_render_sourcepos(cmark_node *node, cmark_strbuf *html, int options) {
  if (CMARK_OPT_SOURCEPOS & options) {
    char nbuf[16];
    int len;
    cmark_strbuf_puts_lit(html, " data-sourcepos=\"");
    len = cmark_itoa(nbuf, cmark_node_get_start_line(node));
    cmark_strbuf_put(html, (const unsigned char *)nbuf, len);
    cmark_strbuf_putc(html, ':');
    len = cmark_itoa(nbuf, cmark_node_get_start_column(node));
    cmark_strbuf_put(html, (const unsigned char *)nbuf, len);
    cmark_strbuf_putc(html, '-');
    len = cmark_itoa(nbuf, cmark_node_get_end_line(node));
    cmark_strbuf_put(html, (const unsigned char *)nbuf, len);
    cmark_strbuf_putc(html, ':');
    len = cmark_itoa(nbuf, cmark_node_get_end_column(node));
    cmark_strbuf_put(html, (const unsigned char *)nbuf, len);
    cmark_strbuf_putc(html, '"');
  }
}


#endif
