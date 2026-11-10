#ifndef PAM_AUTH_H
#define PAM_AUTH_H

int singularity_pam_authenticate(const char *username, const char *password);
int singularity_pam_needs_touch(void);

#endif