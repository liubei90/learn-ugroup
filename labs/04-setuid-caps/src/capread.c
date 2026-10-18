/* labs/04-setuid-caps/src/capread.c
 * 打印 ruid/euid 与 /proc/self/status 的 CapEff，并尝试读取一个文件（默认 /root/secret.txt）。
 * 用途：观察 file capability（setcap cap_dac_override=ep）在没有 SUID 的情况下授予的能力。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char capeff[32] = "?";
    FILE *st = fopen("/proc/self/status", "r");
    if (st != NULL) {
        char line[256];
        while (fgets(line, sizeof line, st) != NULL) {
            if (strncmp(line, "CapEff:", 7) == 0) {
                sscanf(line + 7, "%31s", capeff);
                break;
            }
        }
        fclose(st);
    }
    printf("uid=%u euid=%u CapEff= %s\n", (unsigned)getuid(), (unsigned)geteuid(), capeff);

    const char *path = (argc > 1) ? argv[1] : "/root/secret.txt";
    FILE *fp = fopen(path, "r");
    if (fp == NULL) {
        printf("read %s: DENIED\n", path);
        return 0;
    }
    char buf[128];
    if (fgets(buf, sizeof buf, fp) != NULL) {
        buf[strcspn(buf, "\r\n")] = '\0';
        printf("read %s: OK -> %s\n", path, buf);
    } else {
        printf("read %s: OK (empty)\n", path);
    }
    fclose(fp);
    return 0;
}
