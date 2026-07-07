#!/bin/sh
set -eu

dist="${DIST_DIR:-dist}"

if [ -z "${COURSE_TITLE:-}" ]; then
    echo "COURSE_TITLE is empty; building with an empty course title." >&2
fi

mkdir -p "$dist"
find "$dist" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
mkdir -p "$dist/static/css" "$dist/static/js" "$dist/static/fonts"

elm make src/elm/Main.elm --optimize --output="$dist/static/js/elm.js"
cp src/static/styles/main.css "$dist/static/css/main.css"

cp src/static/index.html "$dist/index.html"
cp src/favicon.ico "$dist/favicon.ico"
cp src/static/fonts/* "$dist/static/fonts/"

{
    printf 'window.YELUKEREST_FLAGS = '
    jq -n \
        --arg courseTitle "${COURSE_TITLE:-}" \
        --arg piazzaURL "${PIAZZA_URL:-}" \
        --arg aboutURL "${ABOUT_URL:-}" \
        --arg canvasURL "${CANVAS_URL:-}" \
        --arg slackURL "${SLACK_URL:-}" \
        'def optional: if . == "" then null else . end;
        {
            courseTitle: $courseTitle,
            piazzaURL: ($piazzaURL | optional),
            aboutURL: $aboutURL,
            canvasURL: $canvasURL,
            slackURL: ($slackURL | optional)
        }'
    cat <<'EOF'
;

(function () {
    var node = document.getElementById("main");

    window.Elm.Main.init({
        flags: Object.assign({}, window.YELUKEREST_FLAGS, {
            location: window.location.href
        }),
        node: node
    });

    document.addEventListener("click", function (event) {
        var node = event.target;

        while (node && node.nodeType !== 1) {
            node = node.parentNode;
        }

        while (node && node.nodeType === 1 && !node.hasAttribute("data-copy-text")) {
            node = node.parentNode;
        }

        if (!node || node.nodeType !== 1 || !navigator.clipboard || !navigator.clipboard.writeText) {
            return;
        }

        navigator.clipboard.writeText(node.getAttribute("data-copy-text"))["catch"](function () {});
    });
}());
EOF
} > "$dist/static/js/init.js"

find "$dist" -type f \( -name '*.css' -o -name '*.html' -o -name '*.js' \) -exec gzip -9 -kf {} \;
