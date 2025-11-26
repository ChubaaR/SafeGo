Email notification parts have been removed from this project.

What changed:

- SendGrid (SendGrid API) and Gmail (nodemailer) functions were removed from `functions/index.js`.
- The Gmail helper file `functions/index_gmail.js` was replaced with a placeholder comment.
- `functions/package.json` was updated to remove `@sendgrid/mail` and `nodemailer` from dependencies.

What remains:

- `functions/index.js` still contains the `sendPushNotification` Cloud Function which listens for documents in the top-level `notifications/` collection and sends FCM via Firebase Admin.

If you intended to remove only email sending but keep email-related docs or lockfiles, run `npm install` inside the `functions/` folder to update `package-lock.json` and node_modules accordingly.

If you'd like, I can also:

- Remove `functions/package-lock.json` and recreate it with `npm install` (recommended if you want a clean lockfile), or
- Delete the placeholder `index_gmail.js` file entirely.

Let me know whether to proceed with cleaning the lockfile or deleting the placeholder file.
