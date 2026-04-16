#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "cmark-gfm_config.h"
#include "cmark-gfm.h"
#include "node.h"
#include "buffer.h"
#include "houdini.h"
#include "syntax_extension.h"
#include "iterator.h"

#define MAX_INDENT 40

// Functions to convert cmark_nodes to XML strings.

static void escape_xml(cmark_strbuf *dest, const unsigned char *source,
                       bufsize_t length) {
  houdini_escape_html0(dest, source, length, 0);
}

struct render_state {
  cmark_strbuf *xml;
  int indent;
};

static inline void indent(struct render_state *state) {
  int i;
  for (i = 0; i < state->indent && i < MAX_INDENT; i++) {
    cmark_strbuf_putc(state->xml, ' ');
  }
}

static int S_render_node(cmark_node *node, cmark_event_type ev_type,
                         struct render_state *state, int options) {
  cmark_strbuf *xml = state->xml;
  bool literal = false;
  cmark_delim_type delim;
  bool entering = (ev_type == CMARK_EVENT_ENTER);
  char nbuf[16];
  int len;

  if (entering) {
    indent(state);
    cmark_strbuf_putc(xml, '<');
    cmark_strbuf_puts(xml, cmark_node_get_type_string(node));

    if (options & CMARK_OPT_SOURCEPOS && node->start_line != 0) {
      cmark_strbuf_puts_lit(xml, " sourcepos=\"");
      len = cmark_itoa(nbuf, node->start_line);
      cmark_strbuf_put(xml, (const unsigned char *)nbuf, len);
      cmark_strbuf_putc(xml, ':');
      len = cmark_itoa(nbuf, node->start_column);
      cmark_strbuf_put(xml, (const unsigned char *)nbuf, len);
      cmark_strbuf_putc(xml, '-');
      len = cmark_itoa(nbuf, node->end_line);
      cmark_strbuf_put(xml, (const unsigned char *)nbuf, len);
      cmark_strbuf_putc(xml, ':');
      len = cmark_itoa(nbuf, node->end_column);
      cmark_strbuf_put(xml, (const unsigned char *)nbuf, len);
      cmark_strbuf_putc(xml, '"');
    }

    if (node->extension && node->extension->xml_attr_func) {
      const char* r = node->extension->xml_attr_func(node->extension, node);
      if (r != NULL)
        cmark_strbuf_puts(xml, r);
    }

    literal = false;

    switch (node->type) {
    case CMARK_NODE_DOCUMENT:
      cmark_strbuf_puts_lit(xml, " xmlns=\"http://commonmark.org/xml/1.0\"");
      break;
    case CMARK_NODE_TEXT:
    case CMARK_NODE_CODE:
    case CMARK_NODE_HTML_BLOCK:
    case CMARK_NODE_HTML_INLINE:
      cmark_strbuf_puts_lit(xml, " xml:space=\"preserve\">");
      escape_xml(xml, node->as.literal.data, node->as.literal.len);
      cmark_strbuf_puts_lit(xml, "</");
      cmark_strbuf_puts(xml, cmark_node_get_type_string(node));
      literal = true;
      break;
    case CMARK_NODE_LIST:
      switch (cmark_node_get_list_type(node)) {
      case CMARK_ORDERED_LIST:
        cmark_strbuf_puts_lit(xml, " type=\"ordered\"");
        cmark_strbuf_puts_lit(xml, " start=\"");
        len = cmark_itoa(nbuf, cmark_node_get_list_start(node));
        cmark_strbuf_put(xml, (const unsigned char *)nbuf, len);
        cmark_strbuf_putc(xml, '"');
        delim = cmark_node_get_list_delim(node);
        if (delim == CMARK_PAREN_DELIM) {
          cmark_strbuf_puts_lit(xml, " delim=\"paren\"");
        } else if (delim == CMARK_PERIOD_DELIM) {
          cmark_strbuf_puts_lit(xml, " delim=\"period\"");
        }
        break;
      case CMARK_BULLET_LIST:
        cmark_strbuf_puts_lit(xml, " type=\"bullet\"");
        break;
      default:
        break;
      }
      if (cmark_node_get_list_tight(node)) {
        cmark_strbuf_puts_lit(xml, " tight=\"true\"");
      } else {
        cmark_strbuf_puts_lit(xml, " tight=\"false\"");
      }
      break;
    case CMARK_NODE_HEADING:
      cmark_strbuf_puts_lit(xml, " level=\"");
      len = cmark_itoa(nbuf, node->as.heading.level);
      cmark_strbuf_put(xml, (const unsigned char *)nbuf, len);
      cmark_strbuf_putc(xml, '"');
      break;
    case CMARK_NODE_CODE_BLOCK:
      if (node->as.code.info.len > 0) {
        cmark_strbuf_puts_lit(xml, " info=\"");
        escape_xml(xml, node->as.code.info.data, node->as.code.info.len);
        cmark_strbuf_putc(xml, '"');
      }
      cmark_strbuf_puts_lit(xml, " xml:space=\"preserve\">");
      escape_xml(xml, node->as.code.literal.data, node->as.code.literal.len);
      cmark_strbuf_puts_lit(xml, "</");
      cmark_strbuf_puts(xml, cmark_node_get_type_string(node));
      literal = true;
      break;
    case CMARK_NODE_CUSTOM_BLOCK:
    case CMARK_NODE_CUSTOM_INLINE:
      cmark_strbuf_puts_lit(xml, " on_enter=\"");
      escape_xml(xml, node->as.custom.on_enter.data,
                 node->as.custom.on_enter.len);
      cmark_strbuf_putc(xml, '"');
      cmark_strbuf_puts_lit(xml, " on_exit=\"");
      escape_xml(xml, node->as.custom.on_exit.data,
                 node->as.custom.on_exit.len);
      cmark_strbuf_putc(xml, '"');
      break;
    case CMARK_NODE_LINK:
    case CMARK_NODE_IMAGE:
      cmark_strbuf_puts_lit(xml, " destination=\"");
      escape_xml(xml, node->as.link.url.data, node->as.link.url.len);
      cmark_strbuf_putc(xml, '"');
      cmark_strbuf_puts_lit(xml, " title=\"");
      escape_xml(xml, node->as.link.title.data, node->as.link.title.len);
      cmark_strbuf_putc(xml, '"');
      break;
    case CMARK_NODE_ATTRIBUTE:
      // TODO
      break;
    default:
      break;
    }
    if (node->first_child) {
      state->indent += 2;
    } else if (!literal) {
      cmark_strbuf_puts_lit(xml, " /");
    }
    cmark_strbuf_puts_lit(xml, ">\n");

  } else if (node->first_child) {
    state->indent -= 2;
    indent(state);
    cmark_strbuf_puts_lit(xml, "</");
    cmark_strbuf_puts(xml, cmark_node_get_type_string(node));
    cmark_strbuf_puts_lit(xml, ">\n");
  }

  return 1;
}

char *cmark_render_xml(cmark_node *root, int options) {
  return cmark_render_xml_with_mem(root, options, cmark_node_mem(root));
}

char *cmark_render_xml_with_mem(cmark_node *root, int options, cmark_mem *mem) {
  char *result;
  cmark_strbuf xml = CMARK_BUF_INIT(mem);
  cmark_strbuf_grow(&xml, 8192);
  cmark_event_type ev_type;
  cmark_node *cur;
  struct render_state state = {&xml, 0};

  cmark_iter *iter = cmark_iter_new(root);

  cmark_strbuf_puts_lit(state.xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
  cmark_strbuf_puts_lit(state.xml,
                    "<!DOCTYPE document SYSTEM \"CommonMark.dtd\">\n");
  while ((ev_type = cmark_iter_next_inline(iter)) != CMARK_EVENT_DONE) {
    cur = cmark_iter_get_node_inline(iter);
    S_render_node(cur, ev_type, &state, options);
  }
  result = (char *)cmark_strbuf_detach(&xml);

  cmark_iter_free(iter);
  return result;
}
