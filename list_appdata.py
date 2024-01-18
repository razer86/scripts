import google.auth
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError


def list_appdata():
  """List all files inserted in the application data folder
  prints file titles with Ids.
  Returns : List of items

  Load pre-authorized user credentials from the environment.
  TODO(developer) - See https://developers.google.com/identity
  for guides on implementing OAuth2 for the application.
  """
  creds, _ = google.auth.default()

  try:
    # call drive api client
    service = build("drive", "v3", credentials=creds)

    # pylint: disable=maybe-no-member
    response = (
        service.files()
        .list(
            spaces="appDataFolder",
            fields="nextPageToken, files(id, name)",
            pageSize=10,
        )
        .execute()
    )
    for file in response.get("files", []):
      # Process change
      print(f'Found file: {file.get("name")}, {file.get("id")}')

  except HttpError as error:
    print(f"An error occurred: {error}")
    response = None

  return response.get("files")


if __name__ == "__main__":
  list_appdata()