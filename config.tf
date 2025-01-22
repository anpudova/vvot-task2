terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

variable "folder_id" {
  type = string
}

variable "cloud_id" {
  type = string
}

variable "zone" {
  type = string
}

variable "telegram_bot_token" {
  type = string
}

variable "webhook_url" {
  type = string
}

variable "new_admin_name" {
  type = string
}

variable "service_account_id" {
  type = string
}

variable "photos_bucket_name" {
  type = string
}

variable "faces_bucket_name" {
  type = string
}

variable "tasks_queue_name" {
  type = string
}

variable "apigw_name" {
  type = string
}

variable "apigw_original_name" {
  type = string
}

variable "face_detection_function_name" {
  type = string
}

variable "face_cut_function_name" {
  type = string
}

variable "bot_function_name" {
  type = string
}

variable "photo_upload_trigger_name" {
  type = string
}

variable "task_queue_trigger_name" {
  type = string
}

resource "yandex_iam_service_account_static_access_key" "new_admin_key" {
  service_account_id = var.service_account_id
  description = "Access key for ${var.new_admin_name}"
}

provider "yandex" {
  service_account_key_file = "key.json"
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone = var.zone
}

resource "yandex_storage_bucket" "photos" {
  bucket = var.photos_bucket_name
  access_key = yandex_iam_service_account_static_access_key.new_admin_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.new_admin_key.secret_key
  acl = "private"
}

resource "yandex_storage_bucket" "faces" {
  bucket = var.faces_bucket_name
  access_key = yandex_iam_service_account_static_access_key.new_admin_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.new_admin_key.secret_key
  acl = "private"
}

resource "yandex_message_queue" "tasks" {
  name = var.tasks_queue_name
  access_key = yandex_iam_service_account_static_access_key.new_admin_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.new_admin_key.secret_key
}

resource "yandex_api_gateway" "apigw" {
  name = var.apigw_name
  spec = <<EOF
openapi: "3.0.0"
info:
  version: 1.0.0
  title: Face Photo API
paths:
  /:
    get:
      summary: Get face photo
      operationId: getFacePhoto
      parameters:
        - name: face
          in: query
          description: User face
          required: true
          schema:
            type: string
            default: 'face'
      x-yc-apigateway-integration:
        type: object_storage
        bucket: ${var.faces_bucket_name}
        service_account_id: ${var.service_account_id}
        object: '{face}'
  EOF
}

resource "yandex_api_gateway" "apigw_original" {
  name = var.apigw_original_name
  spec = <<EOF
openapi: "3.0.0"
info:
  version: 1.0.0
  title: Photo API
paths:
  /:
    get:
      summary: Get photo
      operationId: getPhoto
      parameters:
        - name: photo
          in: query
          description: User photo
          required: true
          schema:
            type: string
            default: 'photo'
      x-yc-apigateway-integration:
        type: object_storage
        bucket: ${var.photos_bucket_name}
        service_account_id: ${var.service_account_id}
        object: '{photo}'
  EOF
}

resource "yandex_function" "bot_function" {
  name = var.bot_function_name
  user_hash = "v1"
  runtime = "python312"
  entrypoint = "index.handler"
  memory = "128"
  execution_timeout = "5"
  service_account_id = var.service_account_id
  environment = {
    API_GATEWAY = yandex_api_gateway.apigw.domain
    TG_BOT_TOKEN = var.telegram_bot_token
    YANDEX_FOLDER_ID = var.folder_id
    YANDEX_STORAGE_ACCESS_KEY = yandex_iam_service_account_static_access_key.new_admin_key.access_key
    API_GATEWAY_ORIGINAL= yandex_api_gateway.apigw_original.domain
    YANDEX_STORAGE_SECRET_KEY = yandex_iam_service_account_static_access_key.new_admin_key.secret_key
    PHOTOS_BUCKET_NAME = var.photos_bucket_name
    FACES_BUCKET_NAME = var.faces_bucket_name  
  }
  content {
    zip_filename = "bot.zip"
  }
  depends_on = [ yandex_api_gateway.apigw, yandex_api_gateway.apigw_original ]
}

resource "yandex_function" "face_detection_function" {
  name = var.face_detection_function_name
  user_hash = "v1"
  runtime = "python312"
  entrypoint = "index.handler"
  memory = "128"
  execution_timeout = "5"
  service_account_id = var.service_account_id
  environment = {
    YANDEX_ACCESS_KEY = yandex_iam_service_account_static_access_key.new_admin_key.access_key
    YANDEX_SECRET_KEY = yandex_iam_service_account_static_access_key.new_admin_key.secret_key
    URL_QUEUE = yandex_message_queue.tasks.id
  }
  content {
    zip_filename = "face_detection.zip"
  }
}

resource "yandex_function" "face_cut_function" {
  name = var.face_cut_function_name
  user_hash = "v1"
  runtime = "python312"
  entrypoint = "index.handler"
  memory = "128"
  execution_timeout = "5"
  service_account_id = var.service_account_id
  environment = {
    YANDEX_STORAGE_ACCESS_KEY = yandex_iam_service_account_static_access_key.new_admin_key.access_key
    YANDEX_STORAGE_SECRET_KEY = yandex_iam_service_account_static_access_key.new_admin_key.secret_key
    PHOTOS_BUCKET_NAME = var.photos_bucket_name
    FACES_BUCKET_NAME = var.faces_bucket_name
  }
  content {
    zip_filename = "face_cut.zip"
  }
}

resource "yandex_function_iam_binding" "function-iam" {
  function_id = yandex_function.bot_function.id
  role        = "functions.functionInvoker"
  members = [
    "system:allUsers",
  ]
  depends_on = [ yandex_function.bot_function ]
}

resource "yandex_function_trigger" "photo_upload_trigger" {
  name = var.photo_upload_trigger_name
  description = "Trigger for photo upload"

  object_storage {
    bucket_id = yandex_storage_bucket.photos.id
    suffix = ".jpg"
    create = true
    batch_cutoff  = 60
  }
  
  function {
    id = yandex_function.face_detection_function.id
    service_account_id = var.service_account_id
    tag = "$latest"
  }
}

resource "yandex_function_trigger" "task_queue_trigger" {
  name = var.task_queue_trigger_name
  description = "Trigger for processing tasks from the queue"

  message_queue {
    queue_id = yandex_message_queue.tasks.arn
    batch_cutoff  = 60
    service_account_id = var.service_account_id
    batch_size = 1000
  }

  function {
    id = yandex_function.face_cut_function.id
    service_account_id = var.service_account_id
    tag = "$latest"
  }
}

provider "null" {}

resource "null_resource" "register_webhook" {
  provisioner "local-exec" {
    when = create
    command = <<EOT
curl -X POST https://api.telegram.org/bot${var.telegram_bot_token}/setWebhook?url=${var.webhook_url}${yandex_function.bot_function.id}
EOT
  }
  depends_on = [ yandex_function.bot_function ]
}

resource "null_resource" "delete_webhook" {
  provisioner "local-exec" {
    when = destroy
    command = <<EOT
curl -X POST https://api.telegram.org/bot${var.telegram_bot_token}/deleteWebhook
EOT
  }
}