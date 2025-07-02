function chooseDirectory() {
    local title="${1:-Choose a directory}"
    local dir=""

    if command -v zenity >/dev/null 2>&1; then
        # Linux (or macOS w/ Zenity + XQuartz)
        dir=$(zenity --file-selection --directory --title="$title")
        if [ $? -ne 0 ]; then
            echo "Selection cancelled."
            return 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS native AppleScript dialog to choose the path
        # also this looks like English but it's actually AppleScript it's kind of cool
        dir=$(osascript <<EOT
            try
                POSIX path of (choose folder with prompt "'"$title"'")
            on error
                return ""
            end try
EOT
        )
        if [ -z "$dir" ]; then
            echo "Selection cancelled."
            return 1
        fi
    else
        # Fallback to a terminal prompt if no GUI tool is available
        echo "$title"
        read -rp "Enter directory path manually: " dir
        if [ -z "$dir" ]; then
            echo "No input provided."
            return 1
        fi
    fi

    echo "$dir"
    return 0
}

function openFolder() {
    local path=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$path"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$path"
    elif command -v gnome-open >/dev/null 2>&1; then
        gnome-open "$path"
    else
        echo "No command found to open the folder, please navigate to '$path' yourself."
    fi
}

function testInternetConnection() {
    curl -s --head https://www.google.com | grep "200 OK" >/dev/null
}

function downloadAndExtractAdb() {
    local downloadUrl="$1"
    local extractTargetPath="$2"

    echo "Downloading platform tools from $downloadUrl..."
    if ! curl -L "$downloadUrl" -o platform-tools.zip; then
        showMessage "Failed to download ADB. Please check your internet connection and try again." "Download Error"
        exit 1
    fi

    if [ ! -f platform-tools.zip ]; then
        showMessage "Platform tools download failed. The file was not created." "Download Error"
        exit 1
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        showMessage "Unzip command not found. Please install unzip to extract the downloaded file." "Download Error"
        exit 1
    fi

    if [ -d "$(dirname "$extractTargetPath")" ]; then
        echo "Destination directory exists: $(dirname "$extractTargetPath")"
    else
        echo "Creating destination directory: $(dirname "$extractTargetPath")"
        mkdir -p "$(dirname "$extractTargetPath")"
    fi

    echo "Extracting ADB and dependencies to $extractTargetPath..."
    if ! unzip -q platform-tools.zip -d "$(dirname "$extractTargetPath")"; then
        showMessage "Failed to extract ADB. Please check the destination path." "Download Error"
        exit 1
    fi

    rm platform-tools.zip
    showMessage "ADB downloaded and extracted successfully."
}

function showMessage() {
    local message=$1
    local title=$2
    if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="$title" --text="$message"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        osascript -e "display dialog \"$message\" with title \"$title\" buttons {\"OK\"}"
    else
        echo "$title: $message"
    fi
}

DestPath=$(chooseDirectory "Choose where to save the wpilog files") || exit 1
echo "Selected directory: $DestPath"

# check if adb command exists
if command -v adb >/dev/null 2>&1; then
    AdbPath=$(command -v adb)
else
    # look for local adb folder (like in the powershell script)
    BasePath="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AdbPath="$BasePath/adb/adb"

   # instlal adb if not found
    if [ ! -x "$AdbPath" ]; then
        echo "ADB not found on system. Attempting download..."

        if ! testInternetConnection; then
            showMessage "ADB is missing and cannot be downloaded because you are not connected to the internet.
            You only need an internet connection the first time you run this script — after that, it will work offline.
            Otherwise, please download ADB manually." "ADB Not Found"
            exit 1
        fi

        platformToolsUrl="https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
        downloadAndExtractAdb "$platformToolsUrl" "$AdbPath"
    fi
fi


# Yay! now we have adb, let's pull the logs
echo "Pulling logs from device..."

# get the filenames and remove any whitespace
AllFiles="$AdbPath" shell "find /sdcard/Android/data -type f -name '*.wpilog' 2>/dev/null" |
    tr -d '\r' | tr -d '\n' | # remove newlines
    sed 's/^\s*//;s/\s*$//'  # remove leading/trailing whitespace

if [ -z "$AllFiles" ]; then
    showMessage "No .wpilog files found in Android/data" "FTC Log Puller"
    exit 0
fi

# pull the files and delete them from the device
for remote in $AllFiles; do
    fileName=$(basename "$remote")
    localFile="$DestPath/$fileName"
    if [ -f "$localFile" ]; then
        echo "Skipping $fileName (already exists)"
        continue
    fi
    echo "Pulling $fileName"
    if ! "$AdbPath" pull "$remote" "$DestPath"; then
        echo "Failed to pull $fileName. Continuing with next file..."
    fi

    echo "Deleting $fileName from device"
    "$AdbPath" shell "rm '$remote'"
done


for file in $AllFiles; do
    echo "Pulling $file..."
    if ! "$AdbPath" pull "$file" "$DestPath"; then
        echo "Failed to pull $file. Continuing with next file..."
    else
        echo "Successfully pulled $file."
    fi
done

# Success!
openFolder "$DestPath"
Show-TopmostMessageBox "Done! Logs saved and deleted from device.
$DestPath" "FTC Log Puller"
