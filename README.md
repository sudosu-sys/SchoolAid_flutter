# Flutter Offline-First Demo: Users & Progress

This is a sample Flutter application demonstrating a robust **offline-first architecture**. The app allows users to create users and save their progress, with all operations fully functional while offline.

Data is cached locally using **Hive** and automatically synced with a remote server via an "outbox" queue when connectivity is restored.

## Features

* **Offline-First Architecture**: All read and write operations work seamlessly without a network connection.
* **Local Caching**: Uses **Hive** to store users and progress data locally.
* **Outbox Queue**: Queues all create/update operations (e.g., creating a new user, saving progress) when offline.
* **Automatic Synchronization**: Uses `connectivity_plus` to detect when the device is online and automatically syncs the outbox with the remote API.
* **Optimistic UI**: New data is added to the local cache immediately for a responsive user experience, even before it's synced.
* **Dynamic API Configuration**: Set the backend API URL at runtime using Dart defines.
* **Tabbed Interface**: Simple 3-tab UI for:
    * Creating new users.
    * Saving progress for existing users.
    * Viewing all progress (with filtering).


## Demo

![Demo of the app in action](https://media3.giphy.com/media/v1.Y2lkPTc5MGI3NjExZjhsYndyOXNmOGNicXdqaHRnNzkxOWhzbDV1c2N6NzBwOXQ0amszciZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/XMfKcrs11O0UBmpcNw/giphy.gif)

## Tech Stack

* **Flutter**: Cross-platform UI toolkit.
* **Dio**: Networking client for API communication.
* **Hive**: Lightweight and fast NoSQL database for local storage and caching.
* **connectivity\_plus**: Detects network connectivity changes to trigger syncs.

## Getting Started

### Prerequisites

1.  **Flutter SDK**: Ensure you have the latest stable version of Flutter installed.
2.  **Backend API**: This project is a frontend client *only*. You must have a running backend server that matches the API specification below.

### Installation

1.  Clone the repository:
    ```bash
    git clone https://github.com/sudosu-sys/SchoolAid_flutter.git
    cd SchoolAid_flutter
    ```

2.  Install dependencies:
    ```bash
    flutter pub get
    ```

### Running the App

You **could** specify your backend's base URL using a `--dart-define` flag when running the app. Or simply do it from the app UI if you choose to.

```bash
# Replace '[http://your-api-url.com](http://your-api-url.com)' with your actual API base URL
flutter run --dart-define=API_BASE_URL=[http://your-api-url.com](http://your-api-url.com)
````

**Example (Android Emulator with Localhost Server):**

If your API is running on `http://localhost:8000` on your host machine, use `10.0.2.2` for the Android emulator:

```bash
flutter run --dart-define=API_BASE_URL=[http://10.0.2.2:8000](http://10.0.2.2:8000)
```

## Backend API Specification

This client expects a backend server to be running with the following endpoints:

### Users

#### `GET /api/users`

  * **Action**: Get a list of all users.
  * **Response Body**:
    ```json
    [
      { "id": 1, "name": "Amina" },
      { "id": 2, "name": "Bilal" }
    ]
    ```

#### `POST /api/users`

  * **Action**: Create a new user.
  * **Request Body**:
    ```json
    { "name": "New User Name" }
    ```
  * **Response Body**: The newly created user object.
    ```json
    {
      "id": 3,
      "name": "New User Name",
      "created_at": "2025-10-25T12:00:00Z"
    }
    ```

-----

### Progress

#### `GET /api/progress`

  * **Action**: Get all progress entries. Can be filtered by a `user_id` query parameter.
  * **Example (All)**: `GET /api/progress`
  * **Example (Filtered)**: `GET /api/progress?user_id=1`
  * **Response Body**: A list of progress objects.
    ```json
    [
      {
        "id": 101,
        "user": { "id": 1, "name": "Amina" },
        "lesson": "Math 1",
        "score": 95,
        "created_at": "2025-10-25T12:30:00Z"
      }
    ]
    ```

#### `POST /api/progress`

  * **Action**: Save a new progress entry for a user.
  * **Request Body**:
    ```json
    {
      "user_id": 1,
      "lesson": "Math 1",
      "score": 95
    }
    ```
  * **Response Body**: The newly created progress object.
    ```json
    {
      "id": 102,
      "user": { "id": 1, "name": "Amina" },
      "lesson": "Math 1",
      "score": 95,
      "created_at": "2025-10-25T12:35:00Z"
    }
    ```

## Core Architecture: `OfflineRepo`

The app's logic is managed by an `OfflineRepo` class, which acts as the single source of truth for all data.

1.  **UI**: The `HomeScreen` widgets only talk to the `OfflineRepo` to read or write data.
2.  **`OfflineRepo`**:
      * **Read**: Always reads directly from the **Hive** cache for instant data access (e.g., `getCachedUsers()`).
      * **Write (Online)**: If online, it sends the request directly to the **Dio** client and, on success, updates the Hive cache with the server's response.
      * **Write (Offline)**: If offline, it creates an "optimistic" entry in the Hive cache (marked as `pending: true`) and adds the request to the `outbox` (another Hive box).
3.  **Sync Service**: A listener on `connectivity_plus` detects when the app comes online. It then triggers `syncOutbox()` in the `OfflineRepo` to process the queued writes FIFO (First-In, First-Out). Once synced, the local "pending" entries are replaced with the real data from the server.

## Project Dependencies

This project relies on the following packages (as defined in `pubspec.yaml`):

```yaml
dependencies:
  flutter:
    sdk: flutter
  dio: ^5.7.0
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  connectivity_plus: ^6.x.x 
```

