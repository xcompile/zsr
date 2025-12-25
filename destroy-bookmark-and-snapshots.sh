#!/bin/bash

# Specify the pool or dataset here
POOL_NAME="tank"
# Define the pool or dataset base name
BASE_DATASET="${POOL_NAME}/openebszfs"

# Function to confirm deletion
confirm_deletion() {
    read -p "Do you want to continue with the deletion? (Y/N): " choice
    case "$choice" in 
        y|Y ) return 0 ;;  # Proceed with deletion
        n|N ) echo "Deletion cancelled."; exit 1 ;;  # Cancel deletion
        * ) echo "Invalid choice. Deletion cancelled."; exit 1 ;;  # Handle invalid input
    esac
}

# Collect all snapshots to delete
echo "Snapshots to be deleted in pool: $POOL_NAME"
for dataset in $(zfs list -H -o name -r $POOL_NAME); do
    snapshots=$(zfs list -H -o name -t snapshot | grep "^$dataset@")
    if [ -n "$snapshots" ]; then
        echo "$snapshots"
    fi
done

# Collect all bookmarks to delete
echo "Bookmarks to be deleted in pool: $POOL_NAME"
bookmarks=$(zfs list -H -o name -t bookmark)
if [ -n "$bookmarks" ]; then
    echo "$bookmarks"
fi

# Confirm deletion
confirm_deletion

# Delete all snapshots
echo "Deleting all snapshots in pool: $POOL_NAME"
for dataset in $(zfs list -H -o name -r $POOL_NAME); do
    snapshots=$(zfs list -H -o name -t snapshot | grep "^$dataset@")
    if [ -n "$snapshots" ]; then
        echo "Deleting snapshots for dataset: $dataset"
        echo "$snapshots" | xargs -n 1 zfs destroy
    fi
done

# Delete all bookmarks
echo "Deleting all bookmarks in pool: $POOL_NAME"
if [ -n "$bookmarks" ]; then
    echo "Deleting bookmarks:"
    echo "$bookmarks" | xargs -n 1 zfs destroy
fi

echo "All specified snapshots and bookmarks have been deleted."



# Iterate over all datasets in the specified pool
for dataset in $(zfs list -H -o name -r "$BASE_DATASET"); do
    echo "Resetting backup:increment-count for dataset: $dataset"
    zfs set backup:increment-count=0 "$dataset"
done

echo "All datasets have been reset."


