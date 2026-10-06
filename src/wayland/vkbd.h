#ifndef SINGULARITY_VKBD_H
#define SINGULARITY_VKBD_H

/* Type a UTF-8 string into the focused window via a Wayland virtual keyboard.
 * Characters of the given layout use its keys, others a generated keymap, so
 * arbitrary characters (emoji included) are inserted. */
void singularity_type_text(const char *utf8);
void singularity_type_text_set_layout(const char *layout, const char *variant);

#endif
