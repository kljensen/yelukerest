#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" Code for pulling data out of the old, meteor-based Yeluke
    and formatting it for import into Yelukerest.
"""
import json
import datetime
from urllib.parse import urlunsplit, urljoin
import click
import ruamel.yaml as ruamel_yaml
import requests
from pymongo import MongoClient


class DateTimeEncoder(json.JSONEncoder):
    """ Handles encoding DateTime objects
    """
    def default(self, o): # pylint: disable=E0202
        """ Checks if something is a datetime and handles output if so,
            otherwise defers to default JSON encoder.
        """
        if isinstance(o, datetime.datetime):
            return o.isoformat()
        return json.JSONEncoder.default(self, o)


def read_yaml(filehandle):
    """ Reads a YAML file from the file system
    """

    yaml = ruamel_yaml.YAML(typ="safe", pure=True)
    data = yaml.load(filehandle)
    return data

@click.group()
def local():
    pass

@local.command()
@click.argument("infile", type=click.File('r'))
@click.argument("outfile", type=click.File('w'))
def json_to_yaml(infile, outfile):
    """ Converts JSON to YAML
    """
    data = json.load(infile)
    yaml = ruamel_yaml.YAML()
    yaml.dump(data, outfile)


def get_mongo_db(mongo_url, database):
    """ Get a mongodb database object given a URL
        and name of a database.
    """
    client = MongoClient(mongo_url)
    db = client[database]
    return db

quiz_meeting_slug_key = "replace:meetings:slug:id"
qqo_key = "child:quiz_question_options"

def lecture_to_quiz(lecture):
    """ Transform a lecture (a dictionary) into a quiz (a dictionary)
    """
    quiz = lecture.get("quiz", {})
    quiz[quiz_meeting_slug_key] = lecture["slug"]
    quiz["is_draft"] = True

    quiz["child:quiz_questions"] = [
        {
            "body": question.get("text"),
            qqo_key: [
                {"body": qqo["text"], "is_correct": qqo["isCorrect"]}
                for qqo in question.get("options", [])
            ]
        }
        for question in quiz.get('questions', [])
    ]
    return quiz

def get_quizzes_from_mongo(db):
    """ Return a list of quiz objects, which are dictionaries.
        Takes a mongodb database object.
    """
    lectures = list(db.lectures.find({}))
    return [lecture_to_quiz(lecture) for lecture in lectures]

def reading_to_markdown(reading):
    """ Converts a reading, which is an object, to markdown format
        returning a string.
    """
    link = "\n*\t[{0}]({1})".format(reading.get("title"), reading.get("url"))
    get = lambda x: reading.get(x, None)
    output = ". ".join(field for field in [link, get("pages"), get("author"), get("source")] if field)
    if not output.endswith("."):
        output += "."
    note = get("note")
    if note:
        output += "  (" + note + ")"
    return output

def lecture2lecture(lecture):
    """ Converts a old format lecture, an object, to 
        a new format lecture
    """
    new_lecture = {
        "slug": lecture["slug"],
        "begins_at": lecture["date"],
        "is_draft": True,
        "duration": "80 minutes",
        "description": lecture["description"],
    }
    readings = lecture.get('readings', [])
    if readings: 
        reading_text = "\nReadings&#58;\n" + "".join(map(reading_to_markdown, readings))
        new_lecture["description"] += reading_text
    return new_lecture

def get_lectures_from_mongo(db):
    """ Return a list of lecture objects, which are dictionaries.
        Takes a mongodb database object.
    """
    lectures = [lecture2lecture(l) for l in db.lectures.find({})]
    return lectures

def yaml_dump(obj, filename, yaml=None):
    """ Dump an object to a file in YAML format
    """
    if yaml is None:
        yaml = ruamel_yaml.YAML()
    ruamel_yaml.scalarstring.walk_tree(obj)
    with open(filename, encoding="utf-8", mode="w") as fh:
        yaml.dump(obj, fh)

@local.command()
@click.argument("mongo_url")
@click.argument("database")
@click.argument("outfile_prefix")
def dump_quizzes(mongo_url, database, outfile_prefix):
    """ Dump quizzes from the old Yeluke mongodb database
        into YAML format. Transform the keys appropriately
        for import into Yelukerest.
    """
    db = get_mongo_db(mongo_url, database)
    quizzes = get_quizzes_from_mongo(db)
    for quiz in quizzes:
        filename = "{0}-{1}.yaml".format(outfile_prefix, quiz[quiz_meeting_slug_key])
        yaml_dump(quiz, filename)

@local.command()
@click.argument("mongo_url")
@click.argument("database")
@click.argument("output_file")
def dump_lectures(mongo_url, database, output_file):
    """ Dump lectures from the old Yeluke mongodb database
        into YAML format. Transform the keys appropriately
        for import into Yelukerest.
    """
    db = get_mongo_db(mongo_url, database)
    lectures = get_lectures_from_mongo(db)
    yaml_dump(lectures, output_file)
    

cli = click.CommandCollection(sources=[local])
if __name__ == "__main__":
    cli(obj={})
