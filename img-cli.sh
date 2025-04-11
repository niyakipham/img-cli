#!/bin/bash

# Script: extract_image_urls.sh
# Description: Extract all image URLs from a given website and preview with chafa in fzf
# Usage: ./extract_image_urls.sh [URL] [OPTIONS]

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
URL=""
OUTPUT_FILE=""
VERBOSE=false
CHECK_HTTP=false
TIMEOUT=10
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
PREVIEW_IMAGES=true
CHAFA_WIDTH=100  # Điều chỉnh chiều rộng thành khoảng 100x100 (chafa sử dụng tỷ lệ 1:2)
CHAFA_HEIGHT=50
CHAFA_OPTIONS="--size ${CHAFA_WIDTH}x${CHAFA_HEIGHT}"

# Supported image extensions
IMAGE_EXTS=("jpg" "jpeg" "png" "gif" "svg" "webp" "bmp" "ico" "tiff")

# Check if required commands are available
check_dependencies() {
    local missing=()
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v fzf &> /dev/null; then
        missing+=("fzf")
        PREVIEW_IMAGES=false
    fi
    
    if ! command -v chafa &> /dev/null; then
        missing+=("chafa")
        PREVIEW_IMAGES=false
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warning: Missing dependencies: ${missing[*]}${NC}"
        if [[ " ${missing[*]} " =~ " chafa " || " ${missing[*]} " =~ " fzf " ]]; then
            echo -e "${YELLOW}Image preview functionality will be disabled${NC}"
        fi
    fi
}

# Help function
show_help() {
    echo -e "${GREEN}Usage: $0 [URL] [OPTIONS]${NC}"
    echo "Options:"
    echo "  -o, --output FILE      Save results to FILE"
    echo "  -v, --verbose          Show verbose output"
    echo "  -c, --check-http       Check if image URLs are accessible (HTTP 200)"
    echo "  -t, --timeout SECONDS  Set timeout for HTTP requests (default: 10)"
    echo "  -n, --no-preview       Disable image preview with chafa"
    echo "  -h, --help             Show this help message"
    echo -e "\nExamples:"
    echo "  $0 https://example.com"
    echo "  $0 https://example.com -o images.txt -v -c"
    echo "  $0 https://example.com -t 5 --check-http"
    echo "  $0 https://example.com -n (disable image preview)"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -c|--check-http)
            CHECK_HTTP=true
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -n|--no-preview)
            PREVIEW_IMAGES=false
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            if [[ -z "$URL" ]]; then
                URL="$1"
            else
                echo -e "${RED}Error: Unknown argument $1${NC}" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Check dependencies
check_dependencies

# Validate URL
if [[ -z "$URL" ]]; then
    echo -e "${RED}Error: URL is required${NC}" >&2
    show_help
    exit 1
fi

# Validate URL format
if [[ ! "$URL" =~ ^https?:// ]]; then
    echo -e "${YELLOW}Warning: URL doesn't start with http:// or https://, adding https:// prefix${NC}"
    URL="https://$URL"
fi

# Temporary files
HTML_CONTENT=$(mktemp)
IMAGE_URLS=$(mktemp)

# Cleanup function
cleanup() {
    rm -f "$HTML_CONTENT" "$IMAGE_URLS"
}
trap cleanup EXIT

# Fetch HTML content
echo -e "${GREEN}Fetching content from: $URL${NC}"
if ! curl -s -L -A "$USER_AGENT" --connect-timeout "$TIMEOUT" "$URL" > "$HTML_CONTENT"; then
    echo -e "${RED}Error: Failed to fetch URL${NC}" >&2
    exit 1
fi

# Extract image URLs (more comprehensive pattern matching)
echo -e "${GREEN}Extracting image URLs...${NC}"

# First pass: Find common img tags and src attributes
grep -Eoi '<img[^>]+src="([^"]+)"' "$HTML_CONTENT" | \
    sed -E 's/<img[^>]+src="([^"]+)"/\1/g' >> "$IMAGE_URLS"

# Second pass: Find srcset attributes
grep -Eoi 'srcset="([^"]+)"' "$HTML_CONTENT" | \
    sed -E 's/srcset="([^"]+)"/\1/g' | \
    tr ',' '\n' | \
    awk '{print $1}' >> "$IMAGE_URLS"

# Third pass: Find background images in CSS
grep -Eoi 'background(-image)?:[^;]*url\(([^)]+)\)' "$HTML_CONTENT" | \
    sed -E 's/background(-image)?:[^;]*url\(([^)]+)\)/\2/g' | \
    tr -d "'\"" >> "$IMAGE_URLS"

# Filter and normalize URLs
echo -e "${GREEN}Processing found URLs...${NC}"

# Process each URL
processed_urls=()
while read -r img_url; do
    # Skip empty lines
    if [[ -z "$img_url" ]]; then
        continue
    fi

    # Remove leading/trailing whitespace
    img_url=$(echo "$img_url" | awk '{$1=$1};1')

    # Handle relative URLs
    if [[ "$img_url" =~ ^// ]]; then
        # Protocol-relative URL
        img_url="https:$img_url"
    elif [[ "$img_url" =~ ^/ ]]; then
        # Root-relative URL
        domain=$(echo "$URL" | awk -F/ '{print $1 "//" $3}')
        img_url="$domain$img_url"
    elif [[ ! "$img_url" =~ ^https?:// ]]; then
        # Path-relative URL
        base_url=$(echo "$URL" | grep -Eo '^https?://[^/]+')
        path=$(echo "$URL" | grep -Eo '^https?://[^/]+/[^/]+/')
        img_url="$path$img_url"
    fi

    # Check if URL matches image extensions
    ext=$(echo "$img_url" | grep -Eoi '\.(jpg|jpeg|png|gif|svg|webp|bmp|ico|tiff)(\?.*)?$' | sed 's/.*\.//' | head -n 1 | tr '[:upper:]' '[:lower:]')
    
    if [[ -z "$ext" ]]; then
        # If no extension, check Content-Type header
        if $CHECK_HTTP; then
            content_type=$(curl -sI -A "$USER_AGENT" --connect-timeout "$TIMEOUT" "$img_url" | grep -i '^Content-Type:' | awk -F'[: /;]+' '{print $2}' | tr '[:upper:]' '[:lower:]')
            if [[ " ${IMAGE_EXTS[@]} " =~ " ${content_type} " ]]; then
                ext="$content_type"
            fi
        else
            # Skip if we can't verify it's an image and no extension
            if $VERBOSE; then
                echo -e "${YELLOW}Skipping (unknown type): $img_url${NC}"
            fi
            continue
        fi
    fi

    # Skip if not an image
    if [[ -z "$ext" ]]; then
        if $VERBOSE; then
            echo -e "${YELLOW}Skipping (not image): $img_url${NC}"
        fi
        continue
    fi

    # Check for duplicates
    if [[ " ${processed_urls[@]} " =~ " ${img_url} " ]]; then
        if $VERBOSE; then
            echo -e "${YELLOW}Skipping (duplicate): $img_url${NC}"
        fi
        continue
    fi

    # HTTP check if enabled
    if $CHECK_HTTP; then
        status_code=$(curl -sI -A "$USER_AGENT" --connect-timeout "$TIMEOUT" -o /dev/null -w "%{http_code}" "$img_url")
        if [[ "$status_code" != "200" ]]; then
            if $VERBOSE; then
                echo -e "${RED}Invalid (HTTP $status_code): $img_url${NC}"
            fi
            continue
        fi
    fi

    # Add to processed URLs
    processed_urls+=("$img_url")
    
    # Output the URL
    if [[ -z "$OUTPUT_FILE" ]]; then
        echo "$img_url"
    fi
    
    if $VERBOSE; then
        echo -e "${GREEN}Found: $img_url${NC}"
    fi
done < <(sort -u "$IMAGE_URLS")

# Save to file if specified
if [[ -n "$OUTPUT_FILE" ]]; then
    printf "%s\n" "${processed_urls[@]}" > "$OUTPUT_FILE"
    echo -e "${GREEN}Results saved to: $OUTPUT_FILE${NC}"
    echo -e "${GREEN}Total image URLs found: ${#processed_urls[@]}${NC}"
fi

# Image preview with chafa and fzf
if $PREVIEW_IMAGES && [[ ${#processed_urls[@]} -gt 0 ]]; then
    echo -e "${GREEN}Preparing image preview (size: ~100x100 chars)...${NC}"
    
    # Create a preview command that shows both the URL and the image
    preview_command="echo 'URL: {}'; echo 'Loading image preview...'; curl -s {} | chafa $CHAFA_OPTIONS"
    
    # Use fzf to display the interactive selector
    selected_url=$(printf "%s\n" "${processed_urls[@]}" | fzf --preview="$preview_command" --preview-window=right:70%:wrap)
    
    if [[ -n "$selected_url" ]]; then
        echo -e "\n${GREEN}Selected image URL:${NC}"
        echo "$selected_url"
        
        # Display the selected image again
        echo -e "\n${GREEN}Image preview (${CHAFA_WIDTH}x${CHAFA_HEIGHT} chars):${NC}"
        if ! curl -s "$selected_url" | chafa $CHAFA_OPTIONS; then
            echo -e "${RED}Failed to display image preview${NC}"
        fi
    else
        echo -e "${YELLOW}No image selected${NC}"
    fi
fi
