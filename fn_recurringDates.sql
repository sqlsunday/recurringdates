IF (OBJECT_ID('dbo.fn_recurringDates') IS NOT NULL)
	DROP FUNCTION dbo.fn_recurringDates
GO
CREATE FUNCTION dbo.fn_recurringDates(
	@wkDayPattern	tinyint=127,	--- 1=Mon, 2=Tue, 3=Mon+Tue, 4=Wed, 8=Thu, 16=Fri, 32=Sat, 64=Sun, 127=Every day
	@dayFrequency	tinyint=1,	--- 1=Every occurrence, 2=every second occurrence
	@exactDay	tinyint=NULL,	--- Specific day number of the month

	@occurrenceNo	tinyint=NULL,	--- 1=First, 2=Second, 3=Third, 4=Fourth, ... 0=Last
	@occurrenceType	tinyint=NULL,	--- ... day of... 1=Week, 2=Month, 3=Year

	@weekFrequency	tinyint=1,	--- 1=Every week, 2=Every 2 weeks, etc.
	@exactWeek	tinyint=NULL,	--- Specific ISO week of the year

	@monPattern	smallint=4095,	--- 1=Jan, 2=Feb, 3=Jan+Feb, 4=March, ..., 4095=Every day
	@monFrequency	tinyint=1,	--- 1=Every occurrence, 2=Every second occurrence, etc.

	@yearFrequency	tinyint=1,	--- 1=Every year, 2=Every 2 years, etc.

	@start		date,		--- Start date of recurrence
	@end		date=NULL,	--- End date of recurrence
	@occurrences	int=NULL	--- Max number of occurrences
)
RETURNS @dates TABLE (
	[date]		date NOT NULL,
	PRIMARY KEY CLUSTERED ([date])
)
AS

BEGIN
	--- Variable declarations:
	DECLARE @occurrenceCount int=0, @year date=@start;

	--- Make sure the parameters are set correctly:
	IF (@occurrences IS NULL AND @end IS NULL) RETURN;
	IF (@occurrenceNo IS NOT NULL AND @occurrenceType IS NULL) SET @occurrenceNo=NULL;

	--- This loop will start off with @year=@start and then
	--- increase @year by one calendar year for every iteration:
	WHILE (@occurrenceCount<@occurrences AND
			DATEDIFF(yy, @start, @year)<@yearFrequency*@occurrences OR
			@year<@end) BEGIN;

		--- Build a recursive common table expression that loops through every
		--- date from @year and one year forward.
		WITH dates ([date], occurrence)
		AS (	SELECT @year, 1
			UNION ALL
			SELECT DATEADD(dd, 1, [date]), occurrence+1
			FROM dates
			WHERE DATEADD(dd, 1, [date])<DATEADD(yy, 1, @year))

		--- INSERT the result into the output table, @dates
		INSERT INTO @dates ([date])
		SELECT [date]
		FROM (
			SELECT [date],
				--- The "ordinal number of the year", i.e. 0, 1, 2, 3, ...
				DATEDIFF(yy, @start, @year) AS yearOrdinal,
				--- The ordinal number of the week (first week,
				--- second, third, ...) starting with @year.
				DENSE_RANK() OVER (ORDER BY DATEPART(yy, [date]), NULLIF(DATEPART(isoww, [date]), 0)) AS wkOrdinal,
				--- Ordinal number of the month, as of @year.
				DENSE_RANK() OVER (ORDER BY DATEPART(yy, [date]), DATEPART(mm, [date])) AS monOrdinal,
				--- Ordinal number of the day, as of @year.
				ROW_NUMBER() OVER (PARTITION BY DATEPART(yy, [date]) ORDER BY [date]) AS dayOrdinal,
				--- Ordinal number of the day, per @occurenceType, as of @year:
				ROW_NUMBER() OVER (PARTITION BY (CASE @occurrenceType
						WHEN 1 THEN DATEPART(isoww, [date])
						WHEN 2 THEN DATEPART(mm, [date])
						END), (CASE WHEN @occurrenceType IN (1, 3) THEN DATEPART(yy, [date]) END)
					ORDER BY [date]) AS dateOrdinal,
				--- dayOrdinal (descending). Used to calculate LAST occurrence (@occurenceNo=0)
				ROW_NUMBER() OVER (PARTITION BY (CASE @occurrenceType
						WHEN 1 THEN DATEPART(isoww, [date])
						WHEN 2 THEN DATEPART(mm, [date])
						END), (CASE WHEN @occurrenceType IN (1, 3) THEN DATEPART(yy, [date]) END)
					ORDER BY [date] DESC) AS dateOrdinalDesc
			FROM dates
			WHERE
				--- Logical AND to filter specific weekdays:
				POWER(2, (DATEPART(dw, [date])+@@DATEFIRST+5)%7) & @wkDayPattern>0 AND
				--- Logical AND to filter specific months:
				POWER(2, DATEPART(mm, [date])-1) & @monPattern>0 AND
				--- Filter specific ISO week numbers:
				(@exactWeek IS NULL OR DATEPART(isoww, [date])=@exactWeek) AND
				--- Filter specific days of the month:
				(@exactDay IS NULL OR DATEPART(dd, [date])=@exactDay)
			) AS sub
		WHERE
			--- Modulo operator, to filter yearly frequencies:
			sub.yearOrdinal%@yearFrequency=0 AND
			--- Modulo operator, to filter monthly frequencies:
			sub.monOrdinal%@monFrequency=0 AND
			--- Modulo operator, to filter weekly frequencies:
			sub.wkOrdinal%@weekFrequency=0 AND
			--- Modulo operator, to filter daily frequencies:
			sub.dateOrdinal%@dayFrequency=0 AND
			--- Filter day ordinal:
			(@occurrenceNo IS NULL OR
			 @occurrenceNo=sub.dateOrdinal OR
			 @occurrenceNo=0 AND sub.dateOrdinalDesc=1) AND
			--- ... and finally, stop if we reach @end:
			sub.[date]<=ISNULL(@end, sub.[date])
		OPTION (MAXRECURSION 366);

		--- Add the number of dates that we've added to the
		--- @dates table to our counter, @occurrenceCount.
		--- Also, increase @year by one year.
		SELECT @occurrenceCount=@occurrenceCount+@@ROWCOUNT,
			@year=DATEADD(yy, 1, @year);
	END;

	RETURN;
END;

GO

SELECT *
FROM dbo.fn_recurringDates(
	DEFAULT, DEFAULT, DEFAULT,	--- Two years
	DEFAULT, DEFAULT,
	DEFAULT, DEFAULT,
	DEFAULT, DEFAULT,
	DEFAULT,
	GETDATE(),
	DATEADD(yy, 2, GETDATE()),
	DEFAULT) AS twoYears
ORDER BY [date]

SELECT *
FROM dbo.fn_recurringDates(
	3, DEFAULT, DEFAULT,	--- Every monday and tuesday
	DEFAULT, DEFAULT,
	DEFAULT, DEFAULT,
	DEFAULT, DEFAULT,
	DEFAULT,
	GETDATE(),
	DATEADD(yy, 1, GETDATE()),
	DEFAULT) AS everyMonTue

SELECT *
FROM dbo.fn_recurringDates(
	32, 1, DEFAULT,		--- Saturday
	1, 2,			--- First in the month in..
	DEFAULT, DEFAULT,
	1024, DEFAULT,		--- .. november
	DEFAULT,
	GETDATE(),
	DATEADD(yy, 4, GETDATE()),
	DEFAULT) AS firstSatNov

SELECT *
FROM dbo.fn_recurringDates(
	64, 1, DEFAULT,		--- Sunday
	0, 2,			--- Last in the month in..
	DEFAULT, DEFAULT,
	4+512, DEFAULT,		--- ... march and october
	DEFAULT,
	GETDATE(),
	DATEADD(yy, 4, GETDATE()),
	DEFAULT) AS daylightSavingsDates

SELECT *
FROM dbo.fn_recurringDates(
	DEFAULT, DEFAULT, 29,	--- Every day, the 29th
	DEFAULT, DEFAULT,
	DEFAULT, DEFAULT,
	2, DEFAULT,		--- Every february
	4,			--- Every four years
	{d '2000-01-01'},	--- From 2000..
	{d '2099-12-31'},	--- ... to 2099
	DEFAULT			--- 
	) AS leapYearDays

SELECT *
FROM dbo.fn_recurringDates(
	64, 3, DEFAULT,		--- Third Sunday
	DEFAULT, DEFAULT,
	DEFAULT, DEFAULT,
	256, 1,			--- Every september
	4,			--- Every four years
	{d '2006-01-01'},	--- From 2010..
	DEFAULT,
	10			--- ... up to 10 occurrences.
	) AS swedishElectionDays
