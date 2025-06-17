#!/bin/bash
python_paths=$(find /usr/bin /usr/local/bin /bin ~/.local/bin ~/.local/lib ~ /opt -maxdepth 2 -type f -name "python*" 2>/dev/null)
if npm --version &>/dev/null; then
  if [ "$(npm --version)" != "$(npm view npm version)" ]; then
    echo "updating npm..."
    npm install npm@latest -g >/dev/null 2>&1
  fi
else
  echo "npm is not installed, installing..."
  if ! apt-get install -y npm; then
    sudo apt-get install -y npm
  fi
fi
IFS=$' ' read -r -a gradio_packages <<< "$(npm search @gradio --parseable --searchlimit=2147483647 | awk '{print $1}' | tr '\n' ' ')"
function extract_js_values() {
    echo "$1" > temp_script.py
    js_values=$("$highest_version_path" - <<EOF
import ast


with open('temp_script.py', 'r') as file:
    script_content = file.read()
parsed_script = ast.parse(script_content)
js_values = []
for node in ast.walk(parsed_script):
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == 'js':
                js_value = node.value
                js_values.append(repr(eval(compile(ast.Expression(js_value), '<string>', 'eval'))))
    elif isinstance(node, ast.Call):
        for keyword in node.keywords:
            if keyword.arg == 'js':
                js_value = keyword.value
                js_values.append(repr(eval(compile(ast.Expression(js_value), '<string>', 'eval'))))
print(js_values)
EOF
)
    echo "$js_values"
    rm temp_script.py
}
function module_available_on_pypi() {
    local module="$1"
    local response
    response=$(curl -s "https://pypi.org/pypi/$module/json")
    if [ $? -eq 0 ] && [[ $response == *"\"$module\""* ]]; then
        return 0
    else
        return 1
    fi
}
function import_to_pip() {
    local import_name="$1"
    declare -A import_map=(
        ["yaml"]="PyYAML"
        ["cv2"]="opencv-python"
        ["bs4"]="beautifulsoup4"
        ["PIL"]="Pillow"
        ["sklearn"]="scikit-learn"
        ["Crypto"]="pycryptodome"
        ["Image"]="Pillow"
        ["lxml"]="lxml"
        ["cupy"]="cupy-cuda12x"
    )
    if [[ -n "${import_map[$import_name]}" ]]; then
        echo "${import_map[$import_name]}"
        return 0
    fi
    if command -v pigar &>/dev/null; then
        local pigar_result
        pigar_result=$(pigar search "$import_name" 2>/dev/null | awk 'NR==1{print $1}')
        if [[ -n "$pigar_result" ]]; then
            echo "$pigar_result"
            return 0
        fi
    fi
    echo "$import_name"
}
if [ -z "$python_paths" ]; then
    echo "Error: No Python interpreter found"
    exit 1
fi
highest_version=0
highest_version_path=""
for path in $python_paths; do
    version=$(echo "$path" | sed -nE 's|.*/python([0-9.]+)$|\1|p')
    if [[ "$version" =~ ^[0-9.]+$ ]] && ( echo "$version > $highest_version" | bc -l > /dev/null ); then
        highest_version="$version"
        highest_version_path="$path"
    fi
done
if [ -z "$highest_version_path" ]; then
    echo "Error: Failed to determine Python interpreter path"
    exit 1
fi
if [[ "$1" == "show-path" ]]; then
    echo "$highest_version_path"
    exit 0
fi
"$highest_version_path" -m ensurepip >/dev/null 2>&1
command -v pigar >/dev/null 2>&1 || "$highest_version_path" -m pip install pigar >/dev/null 2>&1 
script_name="$1"
if [ ! -f "$script_name" ]; then
    echo "Error: script not found"
    exit 1
fi
if [[ "$script_name" != *.py ]]; then
    echo "Error: not a Python script"
    exit 1
fi
imports1=$(grep -oP '^\s*import\s+\K[a-zA-Z0-9_]+' "$script_name")
imports2=$(grep -oP '^\s*from\s+\K[a-zA-Z0-9_]+' "$script_name")
library_names=$(echo -e "$imports1\n$imports2" | sort -u | tr '\n' ' ')
stdlib_modules=$("$highest_version_path" -c '
import sys
import pkgutil
import sysconfig

modules = set(sys.builtin_module_names)
stdlib_path = sysconfig.get_paths()["stdlib"]

for finder, name, ispkg in pkgutil.iter_modules([stdlib_path]):
    modules.add(name)

print("\n".join(sorted(modules)))
')
if [[ "$2" == "show-libraries" ]]; then
    echo "$library_names"
    exit 0
fi
for pkg in $library_names; do
    if python -c "import $pkg" &>/dev/null && ! module_available_on_pypi "$pkg"; then
        continue
    fi
    library=$(import_to_pip "$pkg")
    if module_available_on_pypi "$library"; then
        if ! echo "$stdlib_modules" | grep -qx "$library"; then
            if "$highest_version_path" -m pip show "$library" &>/dev/null; then
                if "$highest_version_path" -m pip list --outdated --format=json | grep -q "\"$library\""; then
                    echo "Upgrading $pkg ..."
                    "$highest_version_path" -m pip install --upgrade "$library" >/dev/null 2>&1
                fi
            else
                echo "Installing $pkg ..."
                "$highest_version_path" -m pip install "$library" >/dev/null 2>&1
            fi
        fi
    fi
done
code=$(cat "$script_name") >/dev/null 2>&1
library_names_js=$(extract_js_values "$code")
if [[ "$code" == *"import gradio as gr"* ]]; then
    echo "Installing gradio npm packages..."
    for package in "${gradio_packages[@]}"; do
        npm install --global "$package"
    done
    if [ -n "$library_names_js" ]; then
        echo "Importing custom js npm packages..."
        for library in $library_names_js; do
            if npm show "$library" &>/dev/null; then
                if npm outdated --json "$library" | grep -q '"current"'; then
                    echo "Upgrading" "$library"
                    npm update --global "$library"
                else
                    echo "Installing" "$library"
                    npm install --global "$library"
                fi
            fi
        done
    fi
fi
echo "Executing script..."
"$highest_version_path" "$script_name"