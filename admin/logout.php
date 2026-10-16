<?php
setcookie("rachel-auth", "", time() - 3600, "/");

require_once("common.php");

header("Location: " . getAbsBaseUrl());
exit;