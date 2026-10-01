#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
CLI_ARCH="amd64"
CLI_OS="linux"
CLI_MAJOR_VER="v2-jf"
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}"
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Print command arguments for debugging purposes.
echo "Running jf installer..."
echo "  CLI_ARCH: ${CLI_ARCH}"
echo "  CLI_OS: ${CLI_OS}"
echo "  CLI_MAJOR_VER: ${CLI_MAJOR_VER}"
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for different versions of jf
declare -A sha512sums
sha512sums=(
    ["2.125.0"]="2372e01b0b660eca6d730b7ab96c1a075e6e33b21f80ce304f8de23c3644c66a4d69945abf5b545b4b456c97606ebb38000f2f2d682a0571205233e800d73a40"
    ["2.124.0"]="095d0738aeca3c5a373d675cb7f544598d22eb4fa980c285274cd21586111fa110a276ad92b4cf0b3640a4a95d6df2a03476ef7ca0ed816ec741d479cea87f27"
    ["2.123.0"]="1835c0a67589190eded2ab13948d8721aa6cd7c141be4b84c46bcb4749eb5fde24adf90f2894933124b048889702a3cafbd4cc13c83a7bb4010d353db734fcba"
    ["2.122.0"]="c63b9bf166364cabb604901244c59bee6fc114e097a06d2ec448530462abe2e967201fd7f088af64c7a4ebded570fd5f90a04553a37ea7281a245f47caa89e3e"
    ["2.121.0"]="0434cb37f6b4908bbd5417045a342e7aaddf9e9062cf853cd91f8be807356f5a5bb967b1047a9604f9fe1d0554455eab0e02744a187725ca2e7898a7d21e87d4"
    ["2.120.0"]="06960f05722eb2aea1d5683557de6beaf9ea26d0f995f72d048eeae3696de9ab68c9ff029ffc2131aadefc87e6a7d2489f67f0ab2ea7e51f9d46bc1de1e69193"
    ["2.119.0"]="d3927607c8eede0f0ed9dc3921805cdb39d220d7ece8edd28d261570dc74bed5312d42621d3ebec758451c6a7a263e4bf4eac08c3baab2b412f559d6297f5808"
    ["2.118.0"]="63f8af5db1394faf6b3d3ba1741bcc8b9c34aaede493b0e1bd0111774084fa7ece41124945dfbac5d9ab24ca218d6c5ddbfeba0e67c629d589b55b83a315f3bb"
    ["2.117.0"]="b32238fda4d5dd9b5b10f6389468065d4774f0cdec9e05d64b573fe17cbc80e8092a7eb9398717dec78e2b8b0ae59b7e4c8b85218a8fa2e653cd7ed675b505aa"
    ["2.116.0"]="c5af7694b970b83d27101ea89fca58a5ad912e6f0a8a4d3d8608192c2256ed3a4f0abc1392d3567c167766e900b5e932388ec0f02e3928efa4ac6bc5571c130f"
    ["2.115.0"]="ef52764a6c03d663dbef35357bfb887363b8cadb5731000502c75469501f5f5aec878df2e7e003c956085bf5332b20026d79e1e21c99903f1379cd359e354321"
    ["2.114.0"]="ff71f8bc366fc25db789c9ebe774afb9ad37dea6eef630639c8449a3becfbe7c24f1568238f9daad067dac695952b0884f1efcaaa51bafc2d337e3fc6e9f7a6d"
    ["2.113.0"]="4940f5737f5deacc5f514aa8ad8e065a372ff56e25c12e14e6805b2176f8f520de3dc90d17dbc5156dcaadd00199522e30d6564fad633854cac71ba41daeda18"
    ["2.112.0"]="f9e180f23b55d2f44241f095fe9a3f7076be4057333464a664f5bc46c1bfc271dd3d5ad83a19c9801f9483ddcb3dbc99fc55ce45851d0a43387fcbdb30acdaeb"
    ["2.111.0"]="08ad4bfae609f5531103a3f0fc6ae90543a6b9fc8ef089aaf086cd1019408e326f4a5c798e7a61f441cc4ec5ed3af7129f82bd0ac3a376380495a01c50300217"
    ["2.110.0"]="d85c08c6e9353d898f8cbe3dc1b96c01825cc3cd54f5741b2540ddebd85156d8615a3cd8f9bf0bb3f13d95ccaefb7c5d1d8e05840dd50a33f1d657fed6858aba"
    ["2.109.0"]="ce1518a87ae55c928df29477fe0d5be08d56597b2be16479a33ec6142633bd0f52bfc7edb38582709588028affa10c6f830e912b0db10cfe221b40e56c1ac865"
    ["2.108.0"]="b8cb50368a83a122ce6ae9be1cd92a199931b5dd9cfc759ccc2d0d31cf5ea3afcdc7039c1042a2c86167c18290285230dd62cea670ff21784aaa286928ec8008"
    ["2.107.0"]="cf63d65e2539d1cbbd386d169d9dcb8c1454607f2370210cb71d974f9a8ffac82460364afd5c985ca75497d10e71fb5be943c4defe9bcea2160e46a3dda9507d"
    ["2.106.0"]="69e5ec72a6e563d0f248ebf53e28267aebbf9b463aa1770ed63dcfdf8ad2a598e5cf87ac03ac42d860fe8a1db10946e00a4f913ea5b9df106d642a438366af98"
    ["2.105.0"]="0065d73fd5615913adeb50be9564072f11b2d6a48952eb058ebf3eaf19e0f7c0f16f7e371ef2f8ef76a2a738625878244352aea26b8ff6f0559482f933fbcc56"
    ["2.104.1"]="aef610e8adce44af98277155d1755541d41343e12d2b83b96ac2956f2e311a0f327f342ddd70e91aa0289afba2bea18a3476d70f8bd948e781173d916c636ea2"
    ["2.104.0"]="a80ceb11562797c78ef705de372f3175f2d5bfb55b35283728e2d19e52039e3eb1a71a0a1b1fb571f4b930f94b90a0d5deb4a500c7d78ca7eaf1818abf113587"
    ["2.103.0"]="8afc229b24bd411f8312eea451ea6dbc873b6f7ea2311ff5de32e17c6c60cb1ed696de93386d951e8a2e9bb01f255457bdfb933b19053a8403eee6e9c5f589b4"
    ["2.102.0"]="59d833097639881e4b9a9ed19b8adab701120018f2b1b3255f842e481e1bf00e5bf8f74a7aa5c70fd2a7872aa7ae80fc0de9f60eb23c22c9d5b7202cb1dc8a56"
    ["2.101.0"]="617fd503d8871ba5dfa29e3bdf4707a2c5e2b56f46f888f47e3a88816ebc6eb209a02e393ca9449f63c1ae66008ce58926f488d68c583c7793c4ab73de1e6de2"
    ["2.100.0"]="b84f6f88e27cd3c78b710a7a3a73ab4adc8b8f1d24232e1a895aaa1c0141fb6dd53532aa8a6f7013ea45365beb0cb1df98b0d43eb5bd9352485a08698cd14776"
    ["2.99.0"]="529daf0df16175ebca4ad341e36b3ffe7e08b0482f4c974e355ead8a2cd1752f116644282d6d3d4c22a0a99f52108d6c85866a5537bc493247287b7888203c60"
    ["2.98.0"]="e196aab14bf2fe4600059201856ec7a07fab7c97e94e4d4bb5348a892e4a90757101292e3cbe04f5a4e56f60eac893accd615fe8de8ddeb53cb23e8868fefd00"
    ["2.97.0"]="176a2f25fd1e3990e3b74cddafb0c6d73e7bc5eb1927b77244b84ec2c5f757c6d321a1c252f711f11bf85b440e1900deee37b27246ec51b86cc0b73762cbf4be"
    ["2.96.0"]="9d64e4f0b87a5454e2613b0baea9ad6a3c031a9bafa59bcee501fbac6de443631f4848424ba10202237fafe1ea70fae695b924904fe0277deeab1d389cda59ea"
    ["2.95.0"]="fb6cf3d029b758052eb18a0e35314948efdabe1b4a5912ad01923eaa9ca254d41c5382a0e6836f071b6d372c53f20ac9c03798b66e39363d7cc2a66639640cfb"
    ["2.94.0"]="6639544f7d2ec542a4cec98f42bae1bb8162c66c3b2bd53c10eff0295c31ba26c7466147f2119506084c0fccf92ae397f10b6b226527b871dfe6f73a32a5ee8c"
    ["2.93.0"]="825f3c0d0aae75dea1cdf47edeb5e30ccdeaa899d31f5d36a5b76bc38cb81c062d21fcdc1dc4463901c97fa70fdadc2fd08ccf9155cb180819d2c6c7d7fd9f0c"
    ["2.92.0"]="01cbd05b7072c616d9e1797aa270d690a623c04ac25738bef36389d28c92705c605fbbd6e8d82d360375c1323dbd7c5d8f4bb6fae051ac4b72fed77b33c5a4a8"
    ["2.91.0"]="583665916b95d7f77a4d5bfc3a26daf364638f6828bcb3a2266aacb29f57611d100d542de91b90b3344896f75d97abc2f65c6f1eb4818f2c95068ff6b11b00c7"
    ["2.90.0"]="c6b17562ef4e861ad543655325d34e37a642dd34f15c3de9501fbbd83363ddfe899035dac5df8caacc7de297b931e5541ec32143b7a6e060f999ea756848c028"
    ["2.89.0"]="0f7240cc0c286838142e301c72fe6420de9027920b08335b41b23f2affc0ba2d8d01521c0dd18d08cbed0cd1552a1f1a9e05296073d9e125c48a6a7614c0335f"
    ["2.88.0"]="801a40291a3fd6af0a8360e06a2dfd748ab0273a7b664815547d1bbd43a5d36307573176ace6652d9692f6cf8b96fc921348b641fc578438e331b76e700b9285"
    ["2.87.0"]="cf4e81029d1b4a17c9de9781770ca29e2a2a0241ceed7d231332b1ac03803c8a042416a5f23a6863b678b6d784bad365ed67d1935ca510beee59fd94f493faa1"
    ["2.86.0"]="ce376c28242fb62d3d4ff182f96161dae33f01b8f8d2e72d5014ae28f9d7f4cbc7ed820c73e1e002f3487c9adf3e2708988f8e620c27c492bb6cdc890d33c2a1"
    ["2.85.0"]="e243f60b53cbce63a13a41ff1caa26104e6d48fb7b1852389340f8d15575fd08af681c958d5c503deb9053b9d785b4f6f462fd9abfbcaf7aaa2cebf1781bfca0"
    ["2.84.0"]="abae87673c25de23a7e99d4cc0ecf1443a118dd9481ecfcce06019b6cd25b8e6ebafaadf44f8d29fbbca42ce851568413a371df2178fff72500a233788cfbaaf"
    ["2.83.0"]="02a10d75249acea832f3f0ba0192c422ef0a2d77f131cad4f18d77c03c4fa40186c93283a3758802fccc2287a0be94c67912f9b5cfdd20f45c2c34e2678ca7d7"
    ["2.82.0"]="d0e50520ba1104f4bb8c896a2cf757218a1d0f3c90fe3cede4d5152e67df85762e41acfde46beb8a314b89869d2bc347d7d9c16c95c2c7570b32228fe5818068"
    ["2.81.0"]="9adf728b79da2e8f7330834b805e30153b5fddb46f8de980c5fedd37f28e26a50afefd95db07ce7d78efec04607231f957b6a8076a0d5ba428432a2597fc5017"
    ["2.80.0"]="d174c3e6979d064d7f2c382725e12faa0cb6440ed9efb9f26981fd61bafafee95a998ea049363a9a074d98c72153ab0c322e0bc2a70c9d741a9adbf508cb4ae2"
    ["2.79.2"]="c7b90e0301cf8ab213d0f00d225e8fee24a33ffbc83ddd72c55c3f826737ae06ef2b0029fde35b4f5b787dc2ad942169690ddbd46d82886253ea0747312015d8"
    ["2.79.1"]="ea5c1ce70dcfee5b49cd347ded9bb8661a9b67c8738b5350520810b30bea20c9039c90e214171c4d1869032ac582cdba6d7afe6175c787666e37a949ec4e19c7"
    ["2.79.0"]="af948d5bfb2bdf23284f7be0a104422a028e46c975fd30568f642aa51ed5cd5191653b87eb8219857fa8e8dfa63953870d9baeebd6d6020bfec2c4e042dec407"
    ["2.78.10"]="c965192a19b04faaba028345c23f89fa3ef6f296cf1fb9cb62b41afcf55118628788451a0bc93047df8ca4661ed75cbf5748e4c5b9374d0f488f84b6fcb14b9b"
    ["2.78.9"]="e91f9e3bcf419288ebd29c574a68625ed0a417f81b09c60d0cda0d55c10b6b9f30c002f18e2a1ef8522da84dd41fb9d10631d0ed1eb10cf773eedcafa0b4f75a"
    ["2.78.8"]="75411ec449ea9144c1577188ed52328ac88fa4eba60f315867322fe8a7a05dd63418fdd585d90559c487eedda749186c2ffed0950b2bb3e5500229830e519463"
    ["2.78.7"]="23aedf10f489d466af447b22e8ee213b3440cbe3c14a162ecb3f9c313fcaca0cd7ba3be38a5feecdae04a16f3ce41f47ac116dce598022b9ea114077ea89a781"
    ["2.78.6"]="c998a3c85d3a41e8c3a41546cafb12c52d7ddc30a4570b65f29316b7f55a0b4c9fa7000be2d7095d85f7e2ee945a539a531367d6008c322f119358f6e26322b8"
    ["2.78.5"]="75a410d2a136d8f5d3edb35421d7223ed17d4c3d269833331ddb3da8c03663db49e70c775e349f41a1ed3fbf3a56e7513b40bd3b70454c282255c1f396069ff6"
    ["2.78.4"]="7ab4a721a2333a6d7f407d01bb4942f1c1b6670cb88c7fde5826f197b9df21b215dc3cc6fc72cd6e5c8dd1a322ce2f826128e5cffa2b536276533ed50daea546"
    ["2.78.3"]="becdc998cd67d7169d7b113c513ce4c6ee9abdf85f8060348058c86cb0ad225de1f2086d741f4e3e9967d3da0ed09d0398c304c1a78d434ec051a391f7871302"
    ["2.78.2"]="afe611354918cb94032c954427f9adde8ea1dd7b2ad1ffc53f45a09ff3ecb04eb2ff230cf408c39a4548cce41b0f8374d01ac67f05b096683e3491908e05d7c6"
    ["2.78.1"]="9a0e7efc6642f4eed941a868a12cebc293adf4bc318432e6f004115e8d21c24d0f6d085a712b201c2c32be429f3431c9ccd7759282dc979588e651f989a7ad5a"
    ["2.78.0"]="7f7c952ae8cf15bbff3dba87f329d3939eb4bc8100a510202c390a1364a5738f1246d2cbcae54c408652ffce7ed554755b776146fa0535a9932dacef11cdfc84"
    ["2.77.0"]="ab071d0c61194b72728b8938f44fe645ff5a76bf19bb62407cfb79b1b3ea5b4d1e68ef35190e51506427cd8a45eadfffe9285dee76562d615aaffe55f840ff1b"
    ["2.76.1"]="058505ad51c235d74472b5e2422a6bbd3e97c6bfab893a2c59e3f3277c375980bda52cac76ab26b5c51aeb2d8b9801991defce873a66e63fb4f0c5631ee49bf6"
    ["2.76.0"]="f2eb22d5b810e135e913d3ede260ab55b45755a13d6043eae5ebb046b5c48b340c198a151cf4ffdaaf723d3458aa78a07b9400fccd6f1c047c0aeb6a31bf7c4b"
    ["2.75.1"]="ff2a1a17d173a7e5a50721d57a37e54e21e39962080a6576fab2eca7054100bdb0d9511487e929543b363096fe8b54f7a5055ba0a60f802e4f97be5f93d84410"
    ["2.75.0"]="5425753e0392e91232e5b7f3ed82caea746a05a130b4e9daaabd568a74999cbf16c84324544ee406197d2fbb90f648a8c2f856d67ed47b59d377f8335fc3cdee"
    ["2.74.1"]="30b5bd2bdd8aa8d3e63c385df258c7261bebe8060b4922d355668c538fa9fc4b612d91269e6ab858a7c3119585c13d53111b83b1c2d03c99b798e829ee8111a9"
    ["2.74.0"]="b2bbd4b5bcdcfb1c0be6f26dd91a18bd8a402878c71e984faad4c465eb585b10d69a7ebb76ccef081eb0fe9bf9693fc496d5423f4bd143497a5e2001185ade1a"
    ["2.73.3"]="a9925a0b132bbd405757ce40d6767efe28172b34c0bc378580ca01c3b659c6c3d06a039e5dfa00c8ee695265a7c99d131a29912422abaf42d050f57af26827ac"
    ["2.73.2"]="7a15ac9753d0ec5edf0d2ffbaebd19d878ae4af77a8ffbc36cd8f08d891299e5c26cf95c76def52614a458eca4d195eccb353c37d7576b366653c0474264a0db"
    ["2.73.1"]="4e15d9a2beef05853889f57904b56c646c57bff177d36a22fc76504b0d4fc73f5ad4d722f3e4312e6fa928821e1505eb366909c143924c72c93d4e02cec9f569"
    ["2.73.0"]="06e4f8d53fc8683f19b5d9186505cc9e8a6fbf8d77daf5c1b11283305b7f975d936a3f98e8cefadd89d52254be9e7b011613508ee8917d9cd42d33ee05b79706"
    ["2.72.5"]="3b78727eb17ced8277cb29ce92bfa83608536d9a5d878d63f46946e3140c51fda7acd3dfa37f4f41cfac8407c620939daaac56037932a12f40fc1eed458944dd"
    ["2.72.4"]="faa4158487fca53db60d1cdd83c599717d6c765622ccf4f42d63038ad3b4579b2b4b06307785ccd1c9da09f5d73128dc8595ba6daf19762dedd3a43de93ebf9c"
    ["2.72.3"]="a9f938cc7910e1a6053212f89f8c5279c83eeb718fa815e4012216aef197f1bcc06036ed1b12872e0dbdc77e8d746cb701a34965556eb563a8f0280d5b523d4e"
    ["2.72.2"]="997fae25064791c289d6a56b9796953f850bb2bae498cca7c86162564e0be68db94dd4d63f13f7a0ee7576a6ff8400280feeb86dd5bdc7f157d8cb63d2f41f10"
    ["2.72.1"]="2ccee9fe16b60e2e9ddd9ab6c03507214c3e4d58c06221dbb057e81ca8a2bc8208473691df1ffb95097aeca0754ceb7784d49a20fc33e4d081ffb6f9a0ac2004"
    ["2.72.0"]="89c8aa0290690028262a00190e934fde830069e528020c7e626d4c42ed65463a20dd94af780855f7a9697caac5e13b530420767004dd33e395c3a592f3dea3e6"
    ["2.71.5"]="fb2c377d5807c8553ae315764f20d72f2f25fa9f5d46c7af02e17d4262f963dde50a4df24d62e8ffaae8544b72d19bb9b11d409da5864a5979a07c583e1222cc"
    ["2.71.4"]="a6fc11b4be0e018264cb4b40c1f973b587408b4912900980ab34cafbdb3ac2b3940862eb7bd9c76ba9975b4ec1cea5e35e9ac4c7c9d0f96b51f2e1584068262c"
    ["2.71.3"]="a2bd1a3e7698770ce8819e7b65eb58bf53fa089669826fe570402b581e56f9c946ab8f25b5ad8ff4fb0481a26a532faac050dcb758e7016df791484449ef8803"
    ["2.71.2"]="eaabf086c262fa819ae0128dc251fdc0bae6443f517427f0bdbccf860bec1364be24c3ec9c8be75f64e58904c4aa84eb3949e665b2332afc0cf212b991a326b5"
    ["2.71.1"]="380ab8608c328f6261dfa9114dab50b2bd330aacd847b806ec93e56ab06ea5e61749f2e9f3c9d470dffc064ff6bc23b0359ceee1e98553dd507a42b6cf7519f7"
    ["2.71.0"]="b4f9da1dc957e26e6c9607128dd95115e4616338c342568830280981c0cf47cca5c708ca18cf0c758ce0494a3f1b6b9513cb8788080554086424a46cdd000258"
    ["2.70.0"]="0e53bc7300f1614f315fa4056074b3c97b86f530f1f3afbb6260116f60b14f1556fda3e43d8bce27e80cdf394deb5ec7ca24739f5232a2f43db9ea48e7c088f8"
)

# Verfies that the SHA-512 checksum of a file matches what was in the lookup table
verify_checksum() {
    local file=$1
    local expected_checksum=$2

    actual_checksum=$(sha512sum "${file}" | awk '{ print $1 }')

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${expected_checksum}"

    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

# Check if the jf tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f jf.tar.gz ]]; then
    tar xvzf jf.tar.gz jf
fi

# If there was no cache hit, go ahead and re-download the binary.
if [[ ! -f jf ]]; then
    if command -v wget &> /dev/null; then
        wget "https://releases.jfrog.io/artifactory/jfrog-cli/${CLI_MAJOR_VER}/${VERSION}/jfrog-cli-${CLI_OS}-${CLI_ARCH}/jf" -O jf
    elif command -v curl &> /dev/null; then
        curl -L "https://releases.jfrog.io/artifactory/jfrog-cli/${CLI_MAJOR_VER}/${VERSION}/jfrog-cli-${CLI_OS}-${CLI_ARCH}/jf" -o jf
    else
        echo "ERROR: Neither wget nor curl is available. Please install one of them."
        exit 1
    fi

    # Tar up the file to save in the CircleCI cache
    tar cvzf jf.tar.gz jf
fi

# An jf binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. First verify its integrity.
if [[ "${VERIFY_CHECKSUMS}" != "false" ]]; then
    EXPECTED_CHECKSUM=${sha512sums[${VERSION}]}
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        # If the version is in the table, verify the checksum
        verify_checksum "jf" "${EXPECTED_CHECKSUM}"
    else
        # If the version is not in the table, this means that a new version of jf
        # was released but this orb hasn't been updated yet to include its checksum in
        # the lookup table. Allow developers to configure if they want this to result in
        # a hard error, via "strict mode" (recommended), or to allow execution for versions
        # not directly specified in the above lookup table.
        if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
            echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
            echo "WARN: Skipping checksum verification..."
        else
            echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
            echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
            exit 1
        fi
    fi
else
    echo "WARN: Checksum validation is disabled. This is not recommended. Skipping..."
fi

# After verifying integrity, install it by moving it to an appropriate bin
# directory and marking it as executable. If your pipeline throws an error
# here, you may want to choose an INSTALL_PATH that doesn't require sudo access,
# so this orb can avoid any root actions.
mv jf "${INSTALL_PATH}/jf"
chmod +x "${INSTALL_PATH}/jf"
