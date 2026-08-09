// notifypost.c — Darwin notify 发送器（替代 notifyutil）
// 用法: notifypost <notify-name>
#include <notify.h>
#include <stdio.h>
int main(int argc, char **argv){
    if(argc<2){ fprintf(stderr,"usage: %s <notify-name>\n", argv[0]); return 1; }
    int r = notify_post(argv[1]);
    fprintf(stderr,"notify_post(%s) = %d\n", argv[1], r);
    return r==0?0:2;
}