# Wsl2 Debian

## bootstrap
1.安装docker 修改properties包名 用户加入docker组

2.`./scripts/run-docker.sh`

>网络问题走代理\
`export http_proxy https_proxy`
```bash
export http_proxy="http://192.168.31.233:7897"
export https_proxy="http://192.168.31.233:7897"
export no_proxy="localhost,127.0.0.1,::1"

export http_proxy="http://192.168.52.232:7897"
export https_proxy="http://192.168.52.232:7897"
export no_proxy="localhost,127.0.0.1,::1"
```

3.`./scripts/build-bootstraps.sh  -f --architectures aarch64`
不重新编译 `./scripts/build-bootstraps.sh --architectures aarch64`
`./scripts/build-bootstraps-old.sh --architectures aarch64`




>缺ndk\
`./scripts/setup-android-sdk.sh`

>建议不要用root来运行,如果以root\
`chown -R builder:builder ~/termux-packages`

>can't read /home/builder/termux-packages/ndk-patches/25b/*.patch: Not a directory\
建立25b软连接 `ln -s 23c 25b`

>get rid of "command-not-found" package from ./scripts/build-bootstraps.sh

>编译一半退出  重试 但去掉-f  啥包编译报错 删啥






