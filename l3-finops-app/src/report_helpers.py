import pandas as pd
from datetime import date, datetime, timedelta
from dateutil.relativedelta import relativedelta
from gspread_dataframe import set_with_dataframe
from src import google_client, queries as Q


def last_month_label():
    today = date.today()
    first_of_this_month = date(today.year, today.month, 1)
    last_day_prev_month = first_of_this_month - timedelta(days=1)
    return last_day_prev_month.strftime("%b %Y")


def run_and_write(cursor, spreadsheet, query, worksheet_name, include_header=False):
    ws = spreadsheet.worksheet(worksheet_name)
    cursor.execute(query)
    columns = [desc[0] for desc in cursor.description]
    data = cursor.fetchall()
    df = pd.DataFrame(data, columns=columns)
    set_with_dataframe(ws, df, row=2, col=1, include_column_header=include_header)
    return df


def populate_google_sheet(cursor, schema_name, sheet_id, gclient, progress_callback=None):
    from src.config import SESSION_VARIABLES

    cursor.execute(f"SET SCHEMA_NAME = '{schema_name}'")
    for stmt in SESSION_VARIABLES:
        cursor.execute(stmt)

    spreadsheet = gclient.open_by_key(sheet_id)

    query_map = {
        "USE_CASES_QUERY_0": Q.USE_CASES_QUERY_0,
        "ADJUSTMENTS_QUERY_1": Q.ADJUSTMENTS_QUERY_1,
        "SCOPED_ACCOUNTS_QUERY_2": Q.SCOPED_ACCOUNTS_QUERY_2,
        "BILL_QUERY_3": Q.BILL_QUERY_3,
        "UEQ_QUERY_4": Q.UEQ_QUERY_4,
        "UEM_QUERY_5": Q.UEM_QUERY_5,
        "WH_QUERY_6": Q.WH_QUERY_6,
        "STORAGE_QUERY_7": Q.STORAGE_QUERY_7,
        "UNUSED_ACTIVE_STORAGE_QUERY_8": Q.UNUSED_ACTIVE_STORAGE_QUERY_8,
        "INACTIVE_STORAGE_QUERY_9": Q.INACTIVE_STORAGE_QUERY_9,
        "REPEATED_QUERIES_10": Q.REPEATED_QUERIES_10,
        "AC_QUERY_11": Q.AC_QUERY_11,
        "AUTO_SUSPEND_QUERY_12": Q.AUTO_SUSPEND_QUERY_12,
        "CLOUD_SERVICES_QUERY_13": Q.CLOUD_SERVICES_QUERY_13,
        "CLOUD_SERVICES_QUERIES_QUERY_14": Q.CLOUD_SERVICES_QUERIES_QUERY_14,
        "ROCKS_QUERY_20": Q.ROCKS_QUERY_20,
        "UEW_QUERY_21": Q.UEW_QUERY_21,
    }

    total = len(Q.QUERY_TO_WORKSHEET)
    for idx, (query_name, worksheet_name) in enumerate(Q.QUERY_TO_WORKSHEET):
        if progress_callback:
            progress_callback(idx / total, f"Writing {worksheet_name}...")
        try:
            run_and_write(cursor, spreadsheet, query_map[query_name], worksheet_name)
        except Exception as e:
            if progress_callback:
                progress_callback(idx / total, f"Warning: {worksheet_name} failed: {e}")

    if progress_callback:
        progress_callback(1.0, "Sheet population complete")


def find_chart_id(sheets_service, spreadsheet_id, sheet_title, chart_title=None):
    spreadsheet = sheets_service.spreadsheets().get(
        spreadsheetId=spreadsheet_id, includeGridData=False
    ).execute()
    for sheet in spreadsheet.get("sheets", []):
        if sheet["properties"]["title"] == sheet_title:
            for chart in sheet.get("charts", []):
                if chart_title is None:
                    return chart["chartId"]
                if chart.get("spec", {}).get("title") == chart_title:
                    return chart["chartId"]
    return None


def replace_chart_on_slide(slides_service, presentation_id, slide_index, spreadsheet_id, chart_id):
    presentation = slides_service.presentations().get(presentationId=presentation_id).execute()
    slide = presentation["slides"][slide_index]
    for element in slide.get("pageElements", []):
        if "sheetsChart" in element:
            size, transform = element.get("size"), element.get("transform")
            slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={"requests": [{"deleteObject": {"objectId": element["objectId"]}}]},
            ).execute()
            slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={"requests": [{"createSheetsChart": {
                    "spreadsheetId": spreadsheet_id,
                    "chartId": chart_id,
                    "linkingMode": "LINKED",
                    "elementProperties": {
                        "pageObjectId": slide["objectId"],
                        "size": size,
                        "transform": transform,
                    },
                }}]},
            ).execute()
            return True
    return False


def replace_multi_charts_on_slide(slides_service, presentation_id, slide_index, spreadsheet_id, chart_ids):
    presentation = slides_service.presentations().get(presentationId=presentation_id).execute()
    slide = presentation["slides"][slide_index]
    charts_info = []
    for element in slide.get("pageElements", []):
        if "sheetsChart" in element:
            charts_info.append({
                "objectId": element["objectId"],
                "size": element.get("size"),
                "transform": element.get("transform"),
            })
    for i, info in enumerate(charts_info):
        if i < len(chart_ids) and chart_ids[i] is not None:
            slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={"requests": [{"deleteObject": {"objectId": info["objectId"]}}]},
            ).execute()
            slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={"requests": [{"createSheetsChart": {
                    "spreadsheetId": spreadsheet_id,
                    "chartId": chart_ids[i],
                    "linkingMode": "LINKED",
                    "elementProperties": {
                        "pageObjectId": slide["objectId"],
                        "size": info["size"],
                        "transform": info["transform"],
                    },
                }}]},
            ).execute()


def replace_chart_send_to_back(slides_service, presentation_id, slide_index, spreadsheet_id, chart_id):
    presentation = slides_service.presentations().get(presentationId=presentation_id).execute()
    slide = presentation["slides"][slide_index]
    for element in slide.get("pageElements", []):
        if "sheetsChart" in element:
            size, transform = element.get("size"), element.get("transform")
            slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={"requests": [{"deleteObject": {"objectId": element["objectId"]}}]},
            ).execute()
            response = slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={"requests": [{"createSheetsChart": {
                    "spreadsheetId": spreadsheet_id,
                    "chartId": chart_id,
                    "linkingMode": "LINKED",
                    "elementProperties": {
                        "pageObjectId": slide["objectId"],
                        "size": size,
                        "transform": transform,
                    },
                }}]},
            ).execute()
            new_chart_id = response["replies"][0]["createSheetsChart"]["objectId"]
            slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={"requests": [{"updatePageElementsZOrder": {
                    "pageElementObjectIds": [new_chart_id],
                    "operation": "SEND_TO_BACK",
                }}]},
            ).execute()
            return True
    return False


def update_table_on_slide(slides_service, presentation_id, slide_index, table_data, safe_delete=False):
    presentation = slides_service.presentations().get(presentationId=presentation_id).execute()
    slide = presentation["slides"][slide_index]
    for element in slide.get("pageElements", []):
        if "table" in element:
            table_id = element["objectId"]
            table_rows = element["table"].get("tableRows", [])
            requests = []
            for row_idx, row in enumerate(table_data):
                for col_idx, value in enumerate(row):
                    if safe_delete:
                        try:
                            existing_text = table_rows[row_idx]["tableCells"][col_idx].get("text", {})
                            has_text = bool(existing_text.get("textElements", []))
                        except (IndexError, KeyError):
                            has_text = False
                        if has_text:
                            requests.append({
                                "deleteText": {
                                    "objectId": table_id,
                                    "cellLocation": {"rowIndex": row_idx, "columnIndex": col_idx},
                                    "textRange": {"type": "ALL"},
                                }
                            })
                    else:
                        requests.append({
                            "deleteText": {
                                "objectId": table_id,
                                "cellLocation": {"rowIndex": row_idx, "columnIndex": col_idx},
                                "textRange": {"type": "ALL"},
                            }
                        })
                    requests.append({
                        "insertText": {
                            "objectId": table_id,
                            "cellLocation": {"rowIndex": row_idx, "columnIndex": col_idx},
                            "text": str(value),
                            "insertionIndex": 0,
                        }
                    })
            if requests:
                slides_service.presentations().batchUpdate(
                    presentationId=presentation_id,
                    body={"requests": requests},
                ).execute()
            return True
    return False


def update_table_with_colors(slides_service, presentation_id, slide_index, rows_data):
    presentation = slides_service.presentations().get(presentationId=presentation_id).execute()
    slide = presentation["slides"][slide_index]
    for element in slide.get("pageElements", []):
        if "table" in element:
            table_id = element["objectId"]
            table_rows = element["table"].get("tableRows", [])
            num_table_rows = element["table"]["rows"]
            num_table_cols = element["table"]["columns"]
            requests = []
            for row_idx, row_data in enumerate(rows_data):
                if row_idx >= num_table_rows:
                    break
                cells = row_data.get("values", [])
                for col_idx, cell in enumerate(cells):
                    if col_idx >= num_table_cols:
                        break
                    value = cell.get("formattedValue", "")
                    bg_color = cell.get("effectiveFormat", {}).get("backgroundColor", {})
                    try:
                        existing_text = table_rows[row_idx]["tableCells"][col_idx].get("text", {})
                        has_text = bool(existing_text.get("textElements", []))
                    except (IndexError, KeyError):
                        has_text = False
                    if has_text:
                        requests.append({
                            "deleteText": {
                                "objectId": table_id,
                                "cellLocation": {"rowIndex": row_idx, "columnIndex": col_idx},
                                "textRange": {"type": "ALL"},
                            }
                        })
                    if value:
                        requests.append({
                            "insertText": {
                                "objectId": table_id,
                                "cellLocation": {"rowIndex": row_idx, "columnIndex": col_idx},
                                "text": str(value),
                                "insertionIndex": 0,
                            }
                        })
                    if bg_color:
                        requests.append({
                            "updateTableCellProperties": {
                                "objectId": table_id,
                                "tableRange": {
                                    "location": {"rowIndex": row_idx, "columnIndex": col_idx},
                                    "rowSpan": 1,
                                    "columnSpan": 1,
                                },
                                "tableCellProperties": {
                                    "tableCellBackgroundFill": {
                                        "solidFill": {"color": {"rgbColor": bg_color}}
                                    }
                                },
                                "fields": "tableCellBackgroundFill",
                            }
                        })
            if requests:
                slides_service.presentations().batchUpdate(
                    presentationId=presentation_id,
                    body={"requests": requests},
                ).execute()
            return True
    return False


def replace_text_placeholders(slides_service, presentation_id, replacements):
    requests = []
    for old_text, new_text in replacements.items():
        requests.append({
            "replaceAllText": {
                "containsText": {"text": old_text, "matchCase": True},
                "replaceText": new_text,
            }
        })
    if requests:
        response = slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={"requests": requests},
        ).execute()
        return sum(r.get("replaceAllText", {}).get("occurrencesChanged", 0) for r in response.get("replies", []))
    return 0


def generate_slides(slides_service, sheets_service, drive_service, presentation_id, sheet_id, customer_name, user_name, progress_callback=None):
    total_steps = 12
    step = 0

    def progress(msg):
        nonlocal step
        step += 1
        if progress_callback:
            progress_callback(min(step / total_steps, 1.0), msg)

    now = datetime.now()
    prev_q = now - relativedelta(months=3)
    start_q = now - relativedelta(months=27)
    last_month = now - relativedelta(months=1)

    progress("Replacing text placeholders...")
    replace_text_placeholders(slides_service, presentation_id, {
        "<COMPANY NAME>": customer_name,
        "<MONTH, YEAR>": now.strftime("%B, %Y"),
        "<subtitle>": user_name,
        "<SLIDE5_DURATION>": f"From {start_q.year}-Q{(start_q.month-1)//3+1} to {prev_q.year}-Q{(prev_q.month-1)//3+1}",
        "<Slide Last Month>": last_month.strftime("%B %Y"),
    })

    spreadsheet = sheets_service.spreadsheets().get(
        spreadsheetId=sheet_id, includeGridData=False
    ).execute()

    progress("Updating Slide 5 (Quarterly Spend)...")
    chart_id = find_chart_id(sheets_service, sheet_id, "Quarterly Spend", "Total Spend")
    if chart_id:
        replace_chart_on_slide(slides_service, presentation_id, 4, sheet_id, chart_id)
    table_data = sheets_service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range="Quarterly Spend!C32:D35"
    ).execute().get("values", [])
    if table_data:
        update_table_on_slide(slides_service, presentation_id, 4, table_data)

    progress("Updating Slide 6 (Monthly Spend)...")
    chart_id = find_chart_id(sheets_service, sheet_id, "Monthly Spend", "Monthly Spend")
    if chart_id:
        replace_chart_on_slide(slides_service, presentation_id, 5, sheet_id, chart_id)
    table_data = sheets_service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range="Monthly Spend!B41:C44"
    ).execute().get("values", [])
    if table_data:
        update_table_on_slide(slides_service, presentation_id, 5, table_data)

    progress("Updating Slide 7 (Account Split)...")
    chart_id = find_chart_id(sheets_service, sheet_id, "Account % of Total Month", "Account Spend % Split")
    if chart_id:
        replace_chart_on_slide(slides_service, presentation_id, 6, sheet_id, chart_id)
    table_data = sheets_service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range="Account % of Total Month!B22:D25"
    ).execute().get("values", [])
    if table_data:
        update_table_on_slide(slides_service, presentation_id, 6, table_data)

    progress("Updating Slide 13 (UEM Monthly)...")
    chart_id = find_chart_id(sheets_service, sheet_id, "UEM - All", "UEM - Monthly")
    if chart_id:
        replace_chart_send_to_back(slides_service, presentation_id, 12, sheet_id, chart_id)
    table_data = sheets_service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range="UEM - All!B2:E16"
    ).execute().get("values", [])
    if table_data:
        update_table_on_slide(slides_service, presentation_id, 12, table_data, safe_delete=True)

    progress("Updating Slide 14 (UEM Charts)...")
    cr_1000j = find_chart_id(sheets_service, sheet_id, "UEM - All", "Cr/1000 Jobs")
    cr_tb = find_chart_id(sheets_service, sheet_id, "UEM - All", "Cr/TB Scanned")
    if cr_1000j or cr_tb:
        replace_multi_charts_on_slide(slides_service, presentation_id, 13, sheet_id, [cr_1000j, cr_tb])

    progress("Updating Slide 16 (Top Tenants)...")
    chart_id = find_chart_id(sheets_service, sheet_id, "Top Tenants")
    if chart_id:
        replace_chart_on_slide(slides_service, presentation_id, 15, sheet_id, chart_id)
    table_data = sheets_service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range="Top Tenants!B2:F19"
    ).execute().get("values", [])
    if table_data:
        update_table_on_slide(slides_service, presentation_id, 15, table_data, safe_delete=True)

    progress("Updating Slide 20 (Tenant Analysis Credits)...")
    table_data = sheets_service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range="Tenant Analysis (All)!B3:H20"
    ).execute().get("values", [])
    if table_data:
        update_table_on_slide(slides_service, presentation_id, 19, table_data, safe_delete=True)

    progress("Updating Slide 21 (Tenant Analysis Storage)...")
    table_data = sheets_service.spreadsheets().values().get(
        spreadsheetId=sheet_id, range="Tenant Analysis (All)!J3:P20"
    ).execute().get("values", [])
    if table_data:
        update_table_on_slide(slides_service, presentation_id, 20, table_data, safe_delete=True)

    progress("Updating Slide 23 (Tenant Growth QoQ)...")
    sheet_data = sheets_service.spreadsheets().get(
        spreadsheetId=sheet_id,
        ranges=["Tenant Growth QoQ!B3:M15"],
        includeGridData=True,
    ).execute()
    grid_data = sheet_data["sheets"][0]["data"][0]
    rows_data = grid_data.get("rowData", [])
    if rows_data:
        header = rows_data[0]
        data_rows = rows_data[1:]

        def get_sort_value(row):
            try:
                cells = row.get("values", [])
                value = cells[9].get("formattedValue", "") if len(cells) > 9 else ""
                return float(value.replace("%", "").replace(",", "").replace("$", "")) if value else float("-inf")
            except Exception:
                return float("-inf")

        data_rows_sorted = sorted(data_rows, key=get_sort_value, reverse=True)
        rows_data = [header] + data_rows_sorted
        update_table_with_colors(slides_service, presentation_id, 22, rows_data)

    progress("Updating Slide 26 (Rocks Summary)...")
    try:
        rocks_data = sheets_service.spreadsheets().values().get(
            spreadsheetId=sheet_id, range="Rocks Summary!J2:I2"
        ).execute().get("values", [[]])[0]
        high_pct = rocks_data[1] if len(rocks_data) > 1 else ""
        low_pct = rocks_data[0] if len(rocks_data) > 0 else ""
        replace_text_placeholders(slides_service, presentation_id, {"<High%>": high_pct, "<Low%>": low_pct})

        rocks_data_v = sheets_service.spreadsheets().values().get(
            spreadsheetId=sheet_id, range="Rocks Summary!J4:I4"
        ).execute().get("values", [[]])[0]
        high_v = rocks_data_v[1] if len(rocks_data_v) > 1 else ""
        low_v = rocks_data_v[0] if len(rocks_data_v) > 0 else ""
        replace_text_placeholders(slides_service, presentation_id, {"<HighV>": high_v, "<LowV>": low_v})
    except Exception:
        pass

    progress("Done!")
    return f"https://docs.google.com/presentation/d/{presentation_id}/edit"
