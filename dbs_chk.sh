#!/bin/bash

# Read MySQL configurations
USER=$(awk -F "=" '/user/ {print $2}' /root/.my.cnf | tr -d ' ')
PASS=$(awk -F "=" '/password/ {print $2}' /root/.my.cnf | tr -d ' ')
HOST='localhost'  # Update if your MySQL host is different

# DB_LIST=$(mysql -u $USER -p$PASS -h $HOST -e 'SHOW DATABASES;' | sed 1d)
DB_LIST=$(mysql --defaults-file=/root/.my.cnf -e 'SHOW DATABASES;' | sed 1d)
ERROR_FLAG=0

for DB in $DB_LIST; do
    TABLE=$(mysql --defaults-file=/root/.my.cnf -e "USE $DB; SHOW TABLES;" | sed 1d | head -1)
    if [ -z "$TABLE" ]; then
        echo "Error: Database $DB has no tables."
        ERROR_FLAG=1
    else
        DATA=$(mysql --defaults-file=/root/.my.cnf -e "USE $DB; SELECT * FROM $TABLE LIMIT 10;")
        if [ -z "$DATA" ]; then
            echo "Error: SELECT * FROM $TABLE returned nothing."
            ERROR_FLAG=1
        else
            echo "Database: $DB"
            echo "Table: $TABLE"
            echo "$DATA"
            echo ""
        fi
    fi
done

if [ $ERROR_FLAG -eq 0 ]; then
    echo "Script executed successfully."
else
    echo "There were some errors."
fi
