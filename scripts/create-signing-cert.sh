#!/bin/bash
# コード署名用の自己署名証明書を作る。
#
# ad-hoc 署名にはアプリを識別する情報が無く、macOS はバイナリのハッシュで
# 判別する。そのため再ビルドや更新のたびに「別のアプリ」とみなされ、
# オートメーションや音声録音の許可を取り直すことになる。
#
# 証明書で署名すると、判定条件が「バンドル ID + この証明書」になるので、
# 中身が変わっても同じアプリとして扱われ、許可が維持される。
#
# Gatekeeper の警告は消えない。それには Apple Developer Program(有償)での
# 公証が必要で、自己署名では代替できない。
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-LyricsOverlay Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "証明書「$NAME」は既にあります。作り直す場合は先に削除してください:"
    echo "  security delete-certificate -c \"$NAME\""
    exit 0
fi

echo "==> 鍵と証明書を作ります(有効期限 10 年)"
# コード署名に必要な拡張。extendedKeyUsage=codeSigning が無いと codesign が使えない。
cat > "$WORK/openssl.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $NAME

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF

# macOS 同梱の openssl を明示して使う。Homebrew の OpenSSL 3 が PATH の先頭に
# あることが多いが、そちらが既定で作る PKCS#12(AES-256 + SHA-256 の MAC)は
# macOS の Security フレームワークが読めず、取り込みに失敗する。
OPENSSL=/usr/bin/openssl

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf"

# キーチェーンへは PKCS#12 でまとめて入れる。
# アルゴリズムは macOS が読める古い組み合わせを明示する。
# パスワードは取り込みが終われば不要なので、その場限りのものを使う。
PASSWORD="$(uuidgen)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "==> キーチェーンへ取り込みます"
# -T で codesign からこの鍵を使えるようにする。
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security

echo "==> コード署名用途で信頼します(管理者認証が要ります)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$WORK/cert.pem"

echo "==> codesign が鍵を使えるようにします(ログインパスワードを聞かれます)"
# これをやらないと、署名のたびにキーチェーンへのアクセス許可を聞かれる。
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null

echo
echo "できました。確認:"
security find-identity -v -p codesigning | grep "$NAME" || true
echo
echo "以後 ./build-app.sh はこの証明書で署名します。"
echo "初回だけ許可(オートメーション・音声録音)を求められ、以降は再ビルドしても聞かれません。"
echo
echo "元に戻す場合:"
echo "  security delete-certificate -c \"$NAME\""
