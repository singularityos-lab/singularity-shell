#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <security/pam_appl.h>
#include "pam_auth.h"

static char *pam_password = NULL;

/* On Sinty OS the lockscreen runs as the SESSION USER and cannot read the
 * root-only key blobs, so pam_sinty -> `sintykey unseal` gives EACCES and the
 * PIN is wrongly rejected (the greeter works only because greetd is root). The
 * CE key is already in the kernel keyring from login, so unlock only needs to
 * VERIFY the PIN: ask the root sinty-recoverd daemon over its socket (verify
 * action, SO_PEERCRED-gated to our own uid, rate-limited). Returns 0 on OK,
 * 1 on FAIL/BLOCKED, -1 if the socket is unreachable (fall back to PAM). */
static int
daemon_verify(const char *pin)
{
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s < 0)
        return -1;
    /* bound the round-trip so a hung/slow daemon cannot freeze the unlock thread
     * ("Authenticating..." forever); a timeout reads as FAIL (closed) and the user
     * can retry. */
    struct timeval tv = { .tv_sec = 4, .tv_usec = 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, "/run/sinty-recoverd.sock", sizeof a.sun_path - 1);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) {
        close(s);
        return -1;
    }
    dprintf(s, "verify\n%u\n%s\n", (unsigned)getuid(), pin ? pin : "");
    char buf[16];
    ssize_t n = read(s, buf, sizeof buf - 1);
    close(s);
    if (n >= 2 && buf[0] == 'O' && buf[1] == 'K')
        return 0;
    return 1;
}

static int
pam_conv_func(int num_msg, const struct pam_message **msg,
              struct pam_response **resp, void *app_data)
{
    if (num_msg <= 0)
        return PAM_CONV_ERR;

    struct pam_response *reply = calloc(num_msg, sizeof(struct pam_response));
    if (!reply)
        return PAM_BUF_ERR;

    for (int i = 0; i < num_msg; i++) {
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF) {
            reply[i].resp = pam_password ? strdup(pam_password) : strdup("");
            reply[i].resp_retcode = 0;
        }
    }

    *resp = reply;
    return PAM_SUCCESS;
}

int
singularity_pam_authenticate(const char *username, const char *password)
{
    /* Sinty OS unlock: verify via the root daemon (the user cannot unseal the
     * root-only key blobs itself). Only when the broker socket is present. */
    if (access("/run/sinty-recoverd.sock", F_OK) == 0) {
        int r = daemon_verify(password);
        if (r >= 0)
            return r == 0 ? PAM_SUCCESS : PAM_AUTH_ERR;
        /* socket present but unreachable -> fall through to PAM below */
    }

    pam_password = (char *)password;

    struct pam_conv conv = {
        .conv = pam_conv_func,
        .appdata_ptr = NULL
    };

    pam_handle_t *pamh = NULL;
    int ret = pam_start("singularity-lockscreen", username, &conv, &pamh);
    if (ret != PAM_SUCCESS) {
        pam_password = NULL;
        return ret;
    }

    ret = pam_authenticate(pamh, 0);
    pam_end(pamh, ret);

    pam_password = NULL;
    return ret;
}
