
# Table of Contents

1.  [ABOS build-rootfs](#orgf781f27)
    1.  [使用方法](#org03f4176)


<a id="orgf781f27"></a>

# ABOS build-rootfs

`build-rootfs` は、Alpine Linux のルートファイルシステムを作成できます。
ただし、そのためには予めビルド環境を構築しておく必要があります。
ビルド環境は、~submodules/containers~ で提供しています。
詳しくは後述の使用方法を読んでください。

出力可能なarch: `aarch64` `armhf` `x86_64`


<a id="org03f4176"></a>

## 使用方法

`build_rootfs.sh` で `build_image.sh` か `swu` 用の OS アーカイブを生成します。
`build_image.sh` で SD カード用の OS かインストーラーを生成します。
詳細はヘルプを読んでください。

    [ATDE ~/build-rootfs]$ ./build_rootfs.sh --help
    [ATDE ~/build-rootfs]$ ./build_image.sh --help

