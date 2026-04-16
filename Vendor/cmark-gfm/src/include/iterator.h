#ifndef CMARK_ITERATOR_H
#define CMARK_ITERATOR_H

#include <assert.h>
#include <stdbool.h>

#include "cmark-gfm.h"
#include "node.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  cmark_event_type ev_type;
  cmark_node *node;
} cmark_iter_state;

struct cmark_iter {
  cmark_mem *mem;
  cmark_node *root;
  cmark_iter_state cur;
  cmark_iter_state next;
};

static inline bool S_is_leaf_inline(cmark_node *node) {
  switch (node->type) {
  case CMARK_NODE_HTML_BLOCK:
  case CMARK_NODE_THEMATIC_BREAK:
  case CMARK_NODE_CODE_BLOCK:
  case CMARK_NODE_TEXT:
  case CMARK_NODE_SOFTBREAK:
  case CMARK_NODE_LINEBREAK:
  case CMARK_NODE_CODE:
  case CMARK_NODE_HTML_INLINE:
    return true;
  }
  return false;
}

static inline cmark_event_type cmark_iter_next_inline(cmark_iter *iter) {
  cmark_event_type ev_type = iter->next.ev_type;
  cmark_node *node = iter->next.node;

  iter->cur.ev_type = ev_type;
  iter->cur.node = node;

  if (ev_type == CMARK_EVENT_DONE) {
    return ev_type;
  }

  /* roll forward to next item, setting both fields */
  if (ev_type == CMARK_EVENT_ENTER && !S_is_leaf_inline(node)) {
    if (node->first_child == NULL) {
      /* stay on this node but exit */
      iter->next.ev_type = CMARK_EVENT_EXIT;
    } else {
      iter->next.ev_type = CMARK_EVENT_ENTER;
      iter->next.node = node->first_child;
    }
  } else if (node == iter->root) {
    /* don't move past root */
    iter->next.ev_type = CMARK_EVENT_DONE;
    iter->next.node = NULL;
  } else if (node->next) {
    iter->next.ev_type = CMARK_EVENT_ENTER;
    iter->next.node = node->next;
  } else if (node->parent) {
    iter->next.ev_type = CMARK_EVENT_EXIT;
    iter->next.node = node->parent;
  } else {
    assert(false);
    iter->next.ev_type = CMARK_EVENT_DONE;
    iter->next.node = NULL;
  }

  return ev_type;
}

static inline cmark_node *cmark_iter_get_node_inline(cmark_iter *iter) {
  return iter->cur.node;
}

#ifdef __cplusplus
}
#endif

#endif
