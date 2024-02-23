#!/bin/bash
python_paths=$(find /usr/bin /usr/local/bin /bin -maxdepth 1 -type f -name "python*" 2>/dev/null)
npm --version &>/dev/null && echo "npm is already installed, updating..." && npm install -g npm || echo "npm is not installed, installing..." && apt-get install -y npm || sudo apt-get install -y npm
IFS=$'\n' read -r -a gradio_packages <<< "$(npm search @gradio --parseable --searchlimit=2147483647 | awk '{print $1}')"
function module_available_on_pypi() {
    local module="$1"
    local response
    response=$(curl -s "https://pypi.org/pypi/$module/json")
    if [[ $response == *"\"$module\""* ]]; then
        return 0
    else
        return 1
    fi
}
if [ -z "$python_paths" ]; then
    echo "Error: No Python interpreter found"
    exit 1
fi
highest_version=0
highest_version_path=""
for path in $python_paths; do
    version=$(echo "$path" | sed -E 's|.*/python([0-9.]+)|\1|')
    if (( $(echo "$version > $highest_version" | bc -l) )); then
        highest_version="$version"
        highest_version_path="$path"
    fi
done
if [ -z "$highest_version_path" ]; then
    echo "Error: Failed to determine Python interpreter path"
    exit 1
fi
"$highest_version_path" -m ensurepip
script_name="$1"
if [ ! -f "$script_name" ]; then
    echo "Error: script not found"
    exit 1
fi
if [[ "$script_name" != *.py ]]; then
    echo "Error: not a Python script"
    exit 1
fi
library_names=$(grep -oP 'import\s+\K[a-zA-Z0-9_]+' "$script_name")
for library in $library_names; do
    if module_available_on_pypi "$library"; then
        if pip show "$library" &>/dev/null && (pip list --outdated | grep -q "^$library") && echo "true" || echo "false"; then
            echo "Upgrading" "$library" "..."
            "$highest_version_path" -m pip install --upgrade "$library"
        else
            echo "Installing" "$library" "..."
            "$highest_version_path" -m pip install "$library"
        fi
    fi
done
code=$(cat "$script_name")
if [[ "$code" == *"import gradio as gr"* ]]; then
    echo "Installing gradio npm packages..."
    for package in "${gradio_packages[@]}"; do
        npm install "$package"
    done
fi
echo "Executing script..."
"$highest_version_path" "$script_name"