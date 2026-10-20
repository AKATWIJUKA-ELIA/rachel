<?php

# Lists installed modules and their sizes in bytes as one JSON object:
#   { "<moddir>": { "moddir": "<moddir>", "ksize": <bytes> }, ... }
# or the JSON string "" when there are no modules.

require_once("admin/common.php");

header("Content-Type: application/json");

$modules = getmods_db();

if (!$modules) {
    echo json_encode("");
    exit;
}

$absModPath = getAbsModPath();
$response   = array();

foreach ($modules as $module) {
    $absPath = $absModPath . "/" . $module['moddir'];

    if (!file_exists($absPath)) {
        continue;
    }

    $moddir   = $module['moddir'];
    $ksize    = get_dir_size($absPath);
    $mod_json = array('moddir' => $moddir,
                      'ksize'  => $ksize);
    $response[$moddir] = $mod_json;
}

echo json_encode($response);
exit;

function get_dir_size($directory){
    $size  = 0;
    $files = glob($directory.'/*');

    foreach($files as $path){
        is_file($path) && $size += filesize($path);
        is_dir($path)  && $size += get_dir_size($path);
    }

    return $size;
}
